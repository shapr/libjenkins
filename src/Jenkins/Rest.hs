{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
-- | Jenkins REST API interface
--
-- This module is intended to be imported qualified.
module Jenkins.Rest
  ( -- * Query Jenkins
    run
  , JenkinsT
  , Jenkins
  , HasMaster(..)
  , Master
  , defaultMaster
    -- ** Combinators
  , get
  , stream
  , post
  , post_
  , orElse
  , orElse_
  , locally
    -- ** Method
  , module Jenkins.Rest.Method
    -- ** Concurrency
  , concurrently
  , Jenkins.Rest.traverse
  , Jenkins.Rest.traverse_
    -- ** Convenience
  , postXml
  , groovy
  , reload
  , restart
  , forceRestart
  , JenkinsException(..)
    -- * Reexports
  , liftIO
  , Http.Request
  ) where

import           Control.Applicative ((<$))
import           Control.Exception.Lifted (try)
import           Control.Monad.IO.Class (MonadIO(..))
import           Control.Monad.Trans.Control (MonadBaseControl(..))
import           Control.Monad.Trans.Resource (MonadResource)
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.ByteString as Strict
import           Data.Conduit (ResumableSource)
import           Data.Data (Data, Typeable)
import qualified Data.Foldable as F
import           Data.Monoid (mempty)
import           Data.Text (Text)
import qualified Data.Text.Lazy as Text.Lazy
import qualified Data.Text.Lazy.Encoding as Text.Lazy
import qualified Network.HTTP.Conduit as Http
import qualified Network.HTTP.Types as Http

import           Jenkins.Rest.Internal
import           Jenkins.Rest.Method
import           Jenkins.Rest.Method.Internal
import           Network.HTTP.Client.Lens.Internal


-- | Run a 'JenkinsT' action
--
-- If a 'JenkinsException' is thrown by performing a request to Jenkins,
-- 'runJenkins' will catch and wrap it in @'Exception'@. Other exceptions
-- will propagate further untouched.
run
  :: (MonadIO m, MonadBaseControl IO m, HasMaster t)
  => t -> JenkinsT m a -> m (Either JenkinsException a)
run c jenk = try (runInternal (c^.url) (c^.user) (c^.apiToken) jenk)

-- | A handy type synonym for the kind of 'JenkinsT' actions that's used the most
type Jenkins = JenkinsT IO

-- | Jenkins master node connection settings
class HasMaster t where
  master :: Lens' t Master

  -- | Jenkins master node URL
  url :: HasMaster t => Lens' t String
  url = master . \f x -> f (_url x) <&> \p -> x { _url = p }
  {-# INLINE url #-}

  -- | Jenkins user
  user :: HasMaster t => Lens' t Text
  user = master . \f x -> f (_user x) <&> \p -> x { _user = p }
  {-# INLINE user #-}

  -- | Jenkins user's password or API token
  apiToken :: HasMaster t => Lens' t Text
  apiToken = master . \f x -> f (_apiToken x) <&> \p -> x { _apiToken = p }
  {-# INLINE apiToken #-}

-- | Jenkins master node connection settings token
data Master = Master
  { _url      :: String -- ^ Jenkins URL
  , _user     :: Text   -- ^ Jenkins user
  , _apiToken :: Text   -- ^ Jenkins user API token or password
  } deriving (Show, Eq, Typeable, Data)

instance HasMaster Master where
  master = id
  {-# INLINE master #-}

-- | Default Jenkins master node connection settings token
--
-- @
-- view 'url'      defaultConnectInfo = \"http:\/\/example.com\/jenkins\"
-- view 'user'     defaultConnectInfo = \"jenkins\"
-- view 'apiToken' defaultConnectInfo = \"secret\"
-- @
defaultMaster :: Master
defaultMaster = Master
  { _url      = "http://example.com/jenkins"
  , _user     = "jenkins"
  , _apiToken = "secret"
  }


-- | Perform a @GET@ request
--
-- While the return type is /lazy/ @Bytestring@, the entire response
-- sits in memory anyway: lazy I/O is not used at the least
get :: Formatter f -> (forall g. Method Complete g) -> JenkinsT m Lazy.ByteString
get (Formatter f) m = liftJ (Get (f m) id)

-- | Perform a streaming @GET@ request
--
-- 'stream', unlike 'get', is constant-space
stream
  :: MonadResource m
  => Formatter f -> (forall g. Method Complete g) -> JenkinsT m (ResumableSource m Strict.ByteString)
stream (Formatter f) m = liftJ (Stream (f m) id)

-- | Perform a @POST@ request
post :: (forall f. Method Complete f) -> Lazy.ByteString -> JenkinsT m Lazy.ByteString
post m body = liftJ (Post m body id)

-- | Perform a @POST@ request without a payload
post_ :: (forall f. Method Complete f) -> JenkinsT m Lazy.ByteString
post_ m = post m mempty

-- | A simple exception handler. If an exception is raised while the action is
-- executed the handler is executed with it as an argument
orElse :: JenkinsT m a -> (JenkinsException -> JenkinsT m a) -> JenkinsT m a
orElse a b = liftJ (Or a b)

-- | A simpler exception handler
--
-- @
-- orElse_ a b = 'orElse' a (\\_ -> b)
-- @
orElse_ :: JenkinsT m a -> JenkinsT m a -> JenkinsT m a
orElse_ a b = orElse a (\_ -> b)
{-# ANN orElse_ ("HLint: ignore Use const" :: String) #-}

-- | @locally f x@ modifies the base 'Request' with @f@ for the execution of @x@
-- (think 'Control.Monad.Trans.Reader.local')
--
-- This is useful for setting the appropriate headers, response timeouts and the like
locally :: (Http.Request -> Http.Request) -> JenkinsT m a -> JenkinsT m a
locally f j = liftJ (With f j id)


-- | Run two actions concurrently
concurrently :: JenkinsT m a -> JenkinsT m b -> JenkinsT m (a, b)
concurrently ja jb = liftJ (Conc ja jb (,))

-- | Map every list element to an action, run them concurrently and collect the results
--
-- @'traverse' : 'Data.Traversable.traverse' :: 'concurrently' : 'Control.Applicative.liftA2' (,)@
traverse :: (a -> JenkinsT m b) -> [a] -> JenkinsT m [b]
traverse f = foldr go (return [])
 where
  go x xs = do (y, ys) <- concurrently (f x) xs; return (y : ys)

-- | Map every list element to an action and run them concurrently ignoring the results
--
-- @'traverse_' : 'Data.Foldable.traverse_' :: 'concurrently' : 'Control.Applicative.liftA2' (,)@
traverse_ :: F.Foldable f => (a -> JenkinsT m b) -> f a -> JenkinsT m ()
traverse_ f = F.foldr (\x xs -> () <$ concurrently (f x) xs) (return ())


-- | Perform a @POST@ request to Jenkins with the XML document
--
-- Sets up the correct @Content-Type@ header. Mostly useful for updating @config.xml@
-- files for jobs, views, etc
postXml :: (forall f. Method Complete f) -> Lazy.ByteString -> JenkinsT m Lazy.ByteString
postXml m = locally (\r -> r { Http.requestHeaders = xmlHeader : Http.requestHeaders r }) . post m
 where
  xmlHeader = ("Content-Type", "text/xml")

-- | Perform a @POST@ request to @/scriptText@
groovy
  :: Text.Lazy.Text            -- ^ Groovy source code
  -> JenkinsT m Text.Lazy.Text
groovy script = locally (\r -> r { Http.requestHeaders = ascii : Http.requestHeaders r }) $
  liftJ (Post "scriptText" body Text.Lazy.decodeUtf8)
 where
  body  = Lazy.fromChunks
    [Http.renderSimpleQuery False [("script", Lazy.toStrict (Text.Lazy.encodeUtf8 script))]]
  ascii = ("Content-Type", "application/x-www-form-urlencoded")

-- | Reload jenkins configuration from disk
--
-- Performs @/reload@
reload :: JenkinsT m ()
reload = () <$ post_ "reload"

-- | Restart jenkins safely
--
-- Performs @/safeRestart@
--
-- @/safeRestart@ allows all running jobs to complete
restart :: JenkinsT m ()
restart = () <$ post_ "safeRestart"

-- | Restart jenkins
--
-- Performs @/restart@
--
-- @/restart@ restart Jenkins immediately, without waiting for the completion of
-- the building and/or waiting jobs
forceRestart :: JenkinsT m ()
forceRestart = () <$ post_ "restart"
