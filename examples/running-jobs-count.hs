{-# LANGUAGE OverloadedStrings #-}
-- | Count running jobs on Jenkins instance
--
-- Usage: count-running-jobs HOST PORT USER APITOKEN
--
-- Uses an awful hack, that is inspecting the job ball color. Jenkins sets
-- it to "blue_anime", meaning "animated blue ball" if job is running
module Main (main) where

import Control.Applicative                       -- base
import Control.Lens                              -- lens
import Control.Lens.Aeson (key, values, _String) -- lens-aeson
import Data.ByteString.Lazy (ByteString)         -- bytestring
import Data.String (fromString)                  -- bytestring
import Jenkins.REST                              -- libjenkins
import System.Environment (getArgs)              -- base
import Text.Printf (printf)                      -- base


main :: IO ()
main = do
  host:port:user:apiToken:_ <- getArgs
  let creds = ConnectInfo host (read port) (fromString user) (fromString apiToken)
  jobs <- runJenkins creds getJobs
  printf "Running jobs count: %d\n" (lengthOf (_Value.running) jobs)

getJobs :: Jenkins ByteString
getJobs = get (json -?- "tree" -=- "jobs[color]")

running :: Fold ByteString ()
running = key "jobs".values.key "color"._String.only "blue_anime"
