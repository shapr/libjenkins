{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
module Jenkins where

import           Control.Concurrent.Async (mapConcurrently)
import           Control.Exception (try, toException)
import           Control.Lens
import           Control.Applicative (Applicative(..))
import           Control.Monad.Free
import           Control.Monad.Trans.Control (liftWith, restoreT)
import           Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import           Data.Conduit (ResourceT)
import           Network.HTTP.Conduit
  ( Manager, Request, RequestBody(..), HttpException
  , withManager, applyBasicAuth, httpLbs, parseUrl, responseBody
  , HttpException(..)
  )
import           Network.HTTP.Types
  (Status(..))
import qualified Network.HTTP.Conduit.Lens as L

import           Jenkins.REST.Method

{-# ANN module ("HLint: Use const" :: String) #-}


newtype Jenkins a = Jenkins { unJenkins :: Free JenkinsF a }

instance Functor Jenkins where
  fmap f = Jenkins . fmap f . unJenkins
  {-# INLINE fmap #-}

instance Applicative Jenkins where
  pure = Jenkins . pure
  {-# INLINE pure #-}
  Jenkins f <*> Jenkins x = Jenkins (f <*> x)
  {-# INLINE (<*>) #-}

instance Monad Jenkins where
  return = pure
  {-# INLINE return #-}
  Jenkins x >>= k = Jenkins (x >>= unJenkins . k)
  {-# INLINE (>>=) #-}


data JenkinsF a =
    forall f. Get (Method Complete f) (BL.ByteString -> a)
  | Post (forall f. Method Complete f) BL.ByteString (BL.ByteString -> a)
  | forall b. Concurrently [Jenkins b] ([b] -> a)

instance Functor JenkinsF where
  fmap f (Get  m g)          = Get  m      (f . g)
  fmap f (Post m body g)     = Post m body (f . g)
  fmap f (Concurrently ms g) = Concurrently ms (f . g)
  {-# INLINE fmap #-}


get :: Method Complete f -> Jenkins BL.ByteString
get m = Jenkins . liftF $ Get m id

post :: (forall f. Method Complete f) -> BL.ByteString -> Jenkins ()
post m body = Jenkins . liftF $ Post m body (\_ -> ())

concurrently :: [Jenkins a] -> Jenkins [a]
concurrently js = Jenkins . liftF $ Concurrently js id


type Host     = String
type Port     = Int
type User     = B.ByteString
type Password = B.ByteString
type APIToken = B.ByteString


withJenkins :: Host -> Port -> User -> Password -> Jenkins a -> IO (Either HttpException a)
withJenkins h p user password jenk = try . withManager $ \manager -> do
  request <- liftIO $ parseUrl h
  let request' = request
        & L.port            .~ p
        & L.responseTimeout .~ Just (20 * 1000000)
  interpret manager (applyBasicAuth user password request') jenk

interpret
  :: Manager -> Request (ResourceT IO) -> Jenkins a -> ResourceT IO a
interpret manager request = iterM go . unJenkins where
  go (Get m next) = do
    let request' = request
          & L.path   %~ (`slash` render m)
          & L.method .~ "GET"
    bs <- httpLbs request' manager
    next (responseBody bs)
  go (Post m body next) = do
    let request' = request
          & L.path          %~ (`slash` render m)
          & L.method        .~ "POST"
          & L.requestBody   .~ RequestBodyLBS body
          & L.redirectCount .~ 0
          & L.checkStatus   .~ \s@(Status st _) hs cookie_jar ->
            if 200 <= st && st < 400
                then Nothing
                else Just . toException $ StatusCodeException s hs cookie_jar
    bs <- httpLbs request' manager
    next (responseBody bs)
  go (Concurrently js next) = do
    xs <- liftWith (\run ->
           mapConcurrently (run . interpret manager request) js)
    ys <- mapM (restoreT . return) xs
    next ys
