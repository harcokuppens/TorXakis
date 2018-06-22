{-
TorXakis - Model Based Testing
Copyright (c) 2015-2017 TNO and Radboud University
See LICENSE at root directory of this repository.
-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
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
import           Control.Monad                    (forever, when)
import           Control.Monad.Except             (MonadError, runExceptT,
                                                   throwError)
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
import           Data.Maybe                       (fromMaybe)
import           Data.String.Utils                (strip)
import qualified Data.Text                        as T
import           Lens.Micro                       ((^.))
import           System.Console.Haskeline
import           System.Console.Haskeline.History (addHistoryRemovingAllDupes)
import           System.Directory                 (doesFileExist,
                                                   getHomeDirectory)
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
        Log.info "Starting the main loop..."
        outputStrLn "Welcome to TorXakis!"
        withMessages $ withInterrupt $ handleInterrupt (output "Ctrl+C: quitting") loop
    loop :: InputT CLIM ()
    loop = do
        minput <- getInputLine (defaultConf ^. prompt)
        Log.info $ "Processing input line: " ++ show (fromMaybe "<no input>" minput)
        case minput of
            Nothing -> return ()
            Just "" -> loop
            Just "q" -> return ()
            Just "quit" -> return ()
            Just "exit" -> return ()
            Just "x" -> return ()
            Just "?" -> showHelp
            Just "h" -> showHelp
            Just "help" -> showHelp
            Just input -> do modifyHistory $ addHistoryRemovingAllDupes (strip input)
                             dispatch input
                             loop
    showHelp :: InputT CLIM ()
    showHelp = do
        outputStrLn helpText
        loop
    dispatch :: String -> InputT CLIM ()
    dispatch inputLine = do
        Log.info $ "Dispatching input: " ++ inputLine
        let tokens = words inputLine
            cmd  = head tokens
            rest = tail tokens
        case map toLower cmd of
            "#"         -> return ()
            "echo"      -> output $ unwords rest
            "delay"     -> waitFor rest
            "i"         -> lift (runExceptT info) >>= output
            "info"      -> lift (runExceptT info) >>= output
            "l"         -> lift (load rest) >>= output
            "load"      -> lift (load rest) >>= output -- TODO: this will break if the file names contain a space.
            "param"     -> lift (runExceptT $ param rest) >>= output
            "run"       -> run rest
            "simulator" -> simulator rest
            "sim"       -> sim rest >>= output
            "stepper"   -> subStepper rest
            "step"      -> subStep rest >>= output
            "stop"      -> stop
            "tester"    -> tester rest
            "test"      -> test rest >>= output
            "time"      -> lift (runExceptT getTime) >>= output
            "timer"     -> lift (runExceptT $ timer rest) >>= output
            "val"       -> lift (runExceptT $ val rest) >>= output
            "var"       -> lift (runExceptT $ var rest) >>= output
            "eval"      -> lift (runExceptT $ eval rest) >>= output
            "solve"     -> lift (runExceptT $ callSolver "sol" rest) >>= output
            "unisolve"  -> lift (runExceptT $ callSolver "uni" rest) >>= output
            "ransolve"  -> lift (runExceptT $ callSolver "ran" rest) >>= output
            "lpe"       -> lift (runExceptT $ callLpe rest) >>= output
            "ncomp"     -> lift (runExceptT $ callNComp rest) >>= output
            "show"      -> lift (runExceptT $ showTxs rest) >>= output
            "menu"      -> lift (runExceptT $ menu rest) >>= output
            "seed"      -> lift (runExceptT $ seed rest) >>= output
            "goto"      -> lift (runExceptT $ goto rest) >>= output
            "back"      -> lift (runExceptT $ back rest) >>= output
            "path"      -> lift (runExceptT getPath) >>= output
            "trace"     -> lift (runExceptT $ trace rest) >>= output
            _           -> output $ "Can't dispatch command: " ++ cmd

          where
            waitFor :: [String] -> InputT CLIM ()
            waitFor [n] = case readMaybe n :: Maybe Int of
                            Nothing -> output $ "Error: " ++ show n ++ " doesn't seem to be an integer."
                            Just s  -> liftIO $ threadDelay (s * 10 ^ (6 :: Int))
            waitFor _ = output "Usage: delay <seconds>"
            -- | Sub-command stepper.
            subStepper :: [String] -> InputT CLIM ()
            subStepper [mName] = lift (stepper mName) >>= output
            subStepper _       = output "This command is not supported yet."
            -- | Sub-command step.
            subStep = lift . step . concat
            tester :: [String] -> InputT CLIM ()
            tester names
                | null names || length names > 4 = output "Usage: tester <model> [<purpose>] [<mapper>] <cnect>"
                | otherwise = lift (startTester names) >>= output
            test :: [String] -> InputT CLIM (Either String ())
            test = lift . testStep . concat
            simulator :: [String] -> InputT CLIM ()
            simulator names
                | null names || length names > 3 = output "Usage: simulator <model> [<mapper>] <cnect>"
                | otherwise = lift (startSimulator names) >>= output
            sim :: [String] -> InputT CLIM (Either String ())
            sim []  = lift (simStep "-1")
            sim [n] = lift (simStep n)
            sim _   = return $ Left "Usage: sim [<step count>]"
            stop :: InputT CLIM ()
            stop = lift stopTxs >>= output
            timer :: (MonadIO m, MonadReader Env m, MonadError String m)
                  => [String] -> m String
            timer [nm] = callTimer nm
            timer _    = return "Usage: timer <timer name>"
            param :: (MonadIO m, MonadReader Env m, MonadError String m)
                  => [String] -> m String
            param []    = getAllParams
            param [p]   = getParam p
            param [p,v] = setParam p v
            param _     = return "Usage: param [ <parameter> [<value>] ]"
            val :: (MonadIO m, MonadReader Env m, MonadError String m)
                => [String] -> m String
            val [] = getVals
            val t  = createVal $ unwords t
            var :: (MonadIO m, MonadReader Env m, MonadError String m)
                => [String] -> m String
            var [] = getVars
            var t  = createVar $ unwords t
            eval :: (MonadIO m, MonadReader Env m, MonadError String m)
                => [String] -> m String
            eval [] = throwError "Usage: eval <value expression>"
            eval t  = evaluate $ unwords t
            callSolver :: (MonadIO m, MonadReader Env m, MonadError String m)
                => String -> [String] -> m String
            callSolver _    [] = throwError "Usage: [uni|ran]solve <value expression>"
            callSolver kind t  = solve kind $ unwords t
            callLpe :: (MonadIO m, MonadReader Env m, MonadError String m)
                => [String] -> m ()
            callLpe [] = throwError "Usage: lpe <model|process>"
            callLpe t  = lpe $ unwords t
            callNComp :: (MonadIO m, MonadReader Env m, MonadError String m)
                => [String] -> m ()
            callNComp [] = throwError "Usage: ncomp <model>"
            callNComp t  = ncomp $ unwords t
            menu :: (MonadIO m, MonadReader Env m, MonadError String m)
                => [String] -> m String
            menu t = getMenu $ unwords t
            seed :: (MonadIO m, MonadReader Env m, MonadError String m)
                 => [String] -> m ()
            seed [s] = setSeed s
            seed _   = throwError "Usage: seed <n>"
            goto :: (MonadIO m, MonadReader Env m, MonadError String m)
                 => [String] -> m String
            goto [st] = case readMaybe st of
                Nothing   -> throwError "Usage: goto <state>"
                Just stNr -> gotoState stNr
            goto _    = throwError "Usage: goto <state>"
            back :: (MonadIO m, MonadReader Env m, MonadError String m)
                 => [String] -> m String
            back []   = backState 1
            back [st] =  case readMaybe st of
                Nothing   -> throwError "Usage: back [<count>]"
                Just stNr -> backState stNr
            back _    = throwError "Usage: back [<count>]"
            trace :: (MonadIO m, MonadReader Env m, MonadError String m)
                 => [String] -> m String
            trace []    = getTrace ""
            trace [fmt] = getTrace fmt
            trace _     = throwError "Usage: trace [<format>]"
            run :: [String] -> InputT CLIM ()
            run [filePath] = do
                exists <- liftIO $ doesFileExist filePath
                if exists
                    then do fileContents <- liftIO $ readFile filePath
                            let script = lines fileContents
                            mapM_ dispatch script
                    else output $ "File " ++ filePath ++ " does not exist."
            run _ = output "Usage: run <file path>"
    withMessages :: InputT CLIM () -> InputT CLIM ()
    withMessages action = do
        Log.info "Starting printer async..."
        printer <- getExternalPrint
        ch <- liftIO newChan
        env <- lift ask
        sId <- lift $ asks sessionId
        Log.info $ "Enabling messages for session " ++ show sId ++ "..."
        res <- lift openMessages
        when (isLeft res) (error $ show res)
        producer <- liftIO $ async $
            sseSubscribe env ch $ concat ["sessions/", show sId, "/messages"]
        consumer <- liftIO $ async $ forever $ do
            Log.info "Waiting for message..."
            msg <- readChan ch
            Log.info $ "Printing message: " ++ show msg
            traverse_ (printer . ("<< " ++)) $ pretty (asTxsMsg msg)
        Log.info "Triggering action..."
        action `finally` do
            Log.info "Closing messages..."
            _ <- lift closeMessages
            liftIO $ do
                cancel producer
                cancel consumer
          where
            asTxsMsg :: BS.ByteString -> Either String Msg
            asTxsMsg msg = do
                msgData <- maybeToEither dataErr $
                    BS.stripPrefix (BS.pack "data:") msg
                eitherDecodeStrict msgData
                    where
                    dataErr = "The message from TorXakis did not contain a \"data:\" field: "
                            ++ show msg

-- | Values that can be output in the command line.
class Outputable v where
    -- | Perform an output action in the @InputT@ monad.
    output :: v -> InputT CLIM ()
    output v = traverse_ logAndOutput (pretty v)
      where
        logAndOutput s = do
            Log.info $ "Showing output: " ++ s
            outputStrLn s

    -- | Format the value as list of strings, to be printed line by line in the
    -- command line.
    pretty :: v -> [String]

instance Outputable () where
    pretty _ = []

instance Outputable String where
    pretty = pure

instance Outputable T.Text where
    pretty = pure . T.unpack

instance Outputable Info where
    pretty i = [ "Version: " ++ T.unpack (i ^. version)
               , "Build time: "++ T.unpack (i ^. buildTime)
               ]

instance (Outputable a, Outputable b) => Outputable (Either a b) where
    pretty = pretty ||| pretty

instance Outputable Msg where
    pretty = pure . pshow