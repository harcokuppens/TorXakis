{-
TorXakis - Model Based Testing
Copyright (c) 2015-2017 TNO and Radboud University
See LICENSE at root directory of this repository.
-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeSynonymInstances       #-}
module TorXakis.CLI
    ( startCLI
    , module TorXakis.CLI.Env
    , runCli
    )
where

import           Control.Arrow                    ((|||))
import           Control.Concurrent               (newChan, readChan,
                                                   threadDelay)
import           Control.Concurrent.Async         (async, cancel)
import           Control.Lens                     ((^.))
import           Control.Monad                    (forever, when)
import           Control.Monad.Except             (runExceptT)
import           Control.Monad.IO.Class           (MonadIO, liftIO)
import           Control.Monad.Reader             (MonadReader, ReaderT, ask,
                                                   asks, runReaderT)
import           Control.Monad.Trans              (lift)
import           Data.Aeson                       (eitherDecodeStrict)
import qualified Data.ByteString.Char8            as BS
import           Data.Char                        (toLower)
import           Data.Either                      (isLeft)
import           Data.Either.Utils                (maybeToEither)
import           Data.Foldable                    (traverse_)
import           Data.String.Utils                (strip)
import qualified Data.Text                        as T
import           System.Console.Haskeline
import           System.Console.Haskeline.History (addHistoryRemovingAllDupes)
import           System.Directory                 (getHomeDirectory)
import           System.FilePath                  ((</>))
import           Text.Read                        (readMaybe)

import           EnvData                          (Msg)
import           TxsShow                          (pshow)

import           TorXakis.CLI.Conf
import           TorXakis.CLI.Env
import           TorXakis.CLI.Help
import qualified TorXakis.CLI.Log                 as Log
import           TorXakis.CLI.WebClient

-- | Client monad
newtype CLIM a = CLIM { innerM :: ReaderT Env IO a }
    deriving (Functor, Applicative, Monad, MonadIO, MonadReader Env, MonadException)

runCli :: Env -> CLIM a -> IO a
runCli e clim = runReaderT (innerM clim) e

startCLI :: CLIM ()
startCLI = do
    home <- liftIO getHomeDirectory
    runInputT (haskelineSettings home) cli
  where
    haskelineSettings home = defaultSettings
        { historyFile = Just $ home </> ".torxakis-hist.txt"
        -- We add entries to the history ourselves, by using
        -- 'addHistoryRemovingAllDupes'.
        , autoAddHistory = False
        }
    cli :: InputT CLIM ()
    cli = do
        sId <- lift $ asks sessionId
        Log.info "Starting printer async..."
        printer <- getExternalPrint
        ch <- liftIO newChan
        env <- lift ask
        -- TODO: maybe encapsulate this into a `withProdCons` that always
        -- cancel the producers and consumers at the end.
        Log.info "Enabling messages..."
        res <- lift openMessages
        when (isLeft res) (error $ show res)
        Log.info "Subscribing to messages..."
        producer <- liftIO $ async $
            sseSubscribe env ch $ concat ["sessions/", show sId, "/messages"]
        consumer <- liftIO $ async $ forever $ do
            msg <- readChan ch
            traverse_ (printer . ("<< " ++)) $ pretty (asTxsMsg msg)
        Log.info "Starting the main loop..."
        outputStrLn "Welcome to TorXakis!"
        withInterrupt $ handleInterrupt (outputStrLn "Ctrl+C: quitting") loop
        Log.info "Closing messages..."
        _ <- lift closeMessages
        liftIO $ do
            cancel producer
            cancel consumer
    loop :: InputT CLIM ()
    loop = do
        minput <- getInputLine (defaultConf ^. prompt)
        case minput of
            Nothing -> return ()
            Just "" -> loop
            Just "q" -> return ()
            Just "quit" -> return () -- stop TorXakis completely
            Just "exit" -> return () -- TODO: exit the current command run of TorXakis; when a file is run, exit ends that run while quit exits TorXakis
            Just "x" -> return ()    -- ^
            Just "?" -> showHelp
            Just "h" -> showHelp
            Just "help" -> showHelp
            Just input -> do dispatch input
                             loop
    showHelp :: InputT CLIM ()
    showHelp = do
        outputStrLn helpText
        loop
    dispatch :: String -> InputT CLIM ()
    dispatch inputLine = do
        modifyHistory $ addHistoryRemovingAllDupes (strip inputLine)
        let tokens = words inputLine -- TODO: this argument parsing should be a bit more sophisticated.
            cmd  = head tokens
            rest = tail tokens
        case map toLower cmd of
            "delay"   -> waitFor $ head rest
            "i"       -> lift (runExceptT info) >>= output
            "info"    -> lift (runExceptT info) >>= output
            "l"       -> lift (load rest) >>= output
            "load"    -> lift (load rest) >>= output -- TODO: this will break if the file names contain a space.
            "stepper" -> subStepper rest >>= output
            "step"    -> subStep rest >>= output
            _         -> output $ "Unknown command: " ++ cmd
          where
            waitFor :: String -> InputT CLIM ()
            waitFor n = case readMaybe n :: Maybe Int of
                            Nothing -> output $ "Error: " ++ show n ++ " doesn't seem to be an integer."
                            Just s  -> liftIO $ threadDelay (s * 10 ^ (6 :: Int))
            -- | Sub-command stepper.
            subStepper :: [String] -> InputT CLIM ()
            subStepper [mName] =
                lift (stepper mName) >>= output
            subStepper _ = outputStrLn "This command is not supported yet."
            -- | Sub-command step.
            subStep with = (lift . step . concat $ with) >>= output
    asTxsMsg :: BS.ByteString -> Either String Msg
    asTxsMsg msg = do
        msgData <- maybeToEither dataErr $
            BS.stripPrefix "data:" msg
        eitherDecodeStrict msgData
            where
              dataErr = "The message from TorXakis did not contain a \"data:\" field: "
                      ++ show msg

-- | Values that can be output in the command line.
class Outputable v where
    -- | Perform an output action in the @InputT@ monad.
    output :: v -> InputT CLIM ()
    output v = traverse_ outputStrLn (pretty v)

    -- | Format the value as list of strings, to be printed line by line in the
    -- command line.
    pretty :: v -> [String]

instance Outputable () where
    pretty _ = []

instance Outputable String where
    pretty = pure

instance Outputable Info where
    pretty i = [ "Version: " ++ T.unpack (i ^. version)
               , "Build time: "++ T.unpack (i ^. buildTime)
               ]

instance (Outputable a, Outputable b) => Outputable (Either a b) where
    pretty = pretty ||| pretty

instance Outputable Msg where
    pretty = pure . pshow
