{-# LANGUAGE CPP                        #-}
{-# LANGUAGE DefaultSignatures          #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImplicitParams             #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}
#if MIN_VERSION_base(4, 9, 0)
{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}
#endif
-- | This module is not meant to be imported directly and may contain
-- internal mechanisms that will change without notice.
module Katip.Core where

-------------------------------------------------------------------------------
import           Control.Applicative          as A
import           Control.AutoUpdate
import           Control.Concurrent
import           Control.Monad.Base
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Control
import           Control.Monad.Trans.Either
import           Control.Monad.Trans.Except
import           Control.Monad.Trans.Maybe
import           Control.Monad.Trans.Reader
import           Control.Monad.Trans.Resource
import           Control.Monad.Trans.State
import           Control.Monad.Trans.Writer
import           Data.Aeson                   (FromJSON (..), ToJSON (..),
                                               object)
import qualified Data.Aeson                   as A
import           Data.Foldable                as FT
import qualified Data.HashMap.Strict          as HM
import           Data.List
import qualified Data.Map.Strict              as M
import           Data.Semigroup
import           Data.String
import           Data.String.Conv
import           Data.Text                    (Text)
import qualified Data.Text                    as T
import qualified Data.Text.Lazy.Builder       as B
import           Data.Time
import           GHC.Generics                 hiding (to)
#if MIN_VERSION_base(4, 8, 0)
#if !MIN_VERSION_base(4, 9, 0)
import           GHC.SrcLoc
#endif
import           GHC.Stack
#endif
import           Language.Haskell.TH
import qualified Language.Haskell.TH.Syntax   as TH
import           Lens.Micro
import           Lens.Micro.TH
import           Network.HostName
#if mingw32_HOST_OS
import           Katip.Compat
#else
import           System.Posix
#endif

-------------------------------------------------------------------------------


readMay :: Read a => String -> Maybe a
readMay s = case [x | (x,t) <- reads s, ("","") <- lex t] of
              [x] -> Just x
              [] -> Nothing -- no parse
              _ -> Nothing -- Ambiguous parse


-------------------------------------------------------------------------------
-- | Represents a heirarchy of namespaces going from general to
-- specific. For instance: ["processname", "subsystem"]. Note that
-- single-segment namespaces can be created using
-- IsString/OverloadedStrings, so "foo" will result in Namespace
-- ["foo"].
newtype Namespace = Namespace { unNamespace :: [Text] }
  deriving (Eq,Show,Read,Ord,Generic,ToJSON,FromJSON,Semigroup,Monoid)

instance IsString Namespace where
    fromString s = Namespace [fromString s]


-------------------------------------------------------------------------------
-- | Ready namespace for emission with dots to join the segments.
intercalateNs :: Namespace -> [Text]
intercalateNs (Namespace xs) = intersperse "." xs


-------------------------------------------------------------------------------
-- | Application environment, like @prod@, @devel@, @testing@.
newtype Environment = Environment { getEnvironment :: Text }
  deriving (Eq,Show,Read,Ord,Generic,ToJSON,FromJSON,IsString)


-------------------------------------------------------------------------------
data Severity
    = DebugS                   -- ^ Debug messages
    | InfoS                    -- ^ Information
    | NoticeS                  -- ^ Normal runtime Conditions
    | WarningS                 -- ^ General Warnings
    | ErrorS                   -- ^ General Errors
    | CriticalS                -- ^ Severe situations
    | AlertS                   -- ^ Take immediate action
    | EmergencyS               -- ^ System is unusable
  deriving (Eq, Ord, Show, Read, Generic, Enum, Bounded)


-------------------------------------------------------------------------------
-- | Verbosity controls the amount of information (columns) a 'Scribe'
-- emits during logging.
--
-- The convention is:
-- - 'V0' implies no additional payload information is included in message.
-- - 'V3' implies the maximum amount of payload information.
-- - Anything in between is left to the discretion of the developer.
data Verbosity = V0 | V1 | V2 | V3
  deriving (Eq, Ord, Show, Read, Generic, Enum)


-------------------------------------------------------------------------------
renderSeverity :: Severity -> Text
renderSeverity s = case s of
      DebugS -> "Debug"
      InfoS -> "Info"
      NoticeS -> "Notice"
      WarningS -> "Warning"
      ErrorS -> "Error"
      CriticalS -> "Critical"
      AlertS -> "Alert"
      EmergencyS -> "Emergency"


-------------------------------------------------------------------------------
textToSeverity :: Text -> Maybe Severity
textToSeverity = go . T.toLower
  where
    go "debug"     = Just DebugS
    go "info"      = Just InfoS
    go "notice"    = Just NoticeS
    go "warning"   = Just WarningS
    go "error"     = Just ErrorS
    go "critical"  = Just CriticalS
    go "alert"     = Just AlertS
    go "emergency" = Just EmergencyS
    go _           = Nothing


instance ToJSON Severity where
    toJSON s = A.String (renderSeverity s)

instance FromJSON Severity where
    parseJSON = A.withText "Severity" parseSeverity
      where
        parseSeverity t = case textToSeverity t of
          Just x -> return x
          Nothing -> fail $ "Invalid Severity " ++ toS t


-------------------------------------------------------------------------------
-- | Log message with Builder unerneath; use '<>' to concat in O(1).
newtype LogStr = LogStr { unLogStr :: B.Builder }
    deriving (Generic, Show)

instance IsString LogStr where
    fromString = LogStr . B.fromString


instance Semigroup LogStr where
  (LogStr a) <> (LogStr b) = LogStr (a <> b)


instance Monoid LogStr where
    mappend = (<>)
    mempty = LogStr mempty


instance FromJSON LogStr where
    parseJSON = A.withText "LogStr" parseLogStr
      where
        parseLogStr = return . LogStr . B.fromText

-------------------------------------------------------------------------------
-- | Pack any string-like thing into a 'LogStr'. This will
-- automatically work on 'String', 'ByteString, 'Text' and any of the
-- lazy variants.
logStr :: StringConv a Text => a -> LogStr
logStr t = LogStr (B.fromText $ toS t)


-------------------------------------------------------------------------------
-- | Shorthand for 'logStr'
ls :: StringConv a Text => a -> LogStr
ls = logStr


-------------------------------------------------------------------------------
-- | Convert any showable type into a 'LogStr'.
showLS :: Show a => a -> LogStr
showLS = ls . show


-------------------------------------------------------------------------------
newtype ThreadIdText = ThreadIdText {
      getThreadIdText :: Text
    } deriving (ToJSON, FromJSON, Show, Eq, Ord)


mkThreadIdText :: ThreadId -> ThreadIdText
mkThreadIdText = ThreadIdText . T.pack . show


-------------------------------------------------------------------------------
-- | This has everything each log message will contain.
data Item a = Item {
      _itemApp       :: Namespace
    , _itemEnv       :: Environment
    , _itemSeverity  :: Severity
    , _itemThread    :: ThreadIdText
    , _itemHost      :: HostName
    , _itemProcess   :: ProcessID
    , _itemPayload   :: a
    , _itemMessage   :: LogStr
    , _itemTime      :: UTCTime
    , _itemNamespace :: Namespace
    , _itemLoc       :: Maybe Loc
    } deriving (Generic, Functor)
makeLenses ''Item


instance Show a => Show (Item a) where
    show Item{..} = "Item {_itemApp = " ++ show _itemApp ++ ", " ++
                          "_itemEnv = " ++ show _itemEnv ++ ", " ++
                          "_itemSeverity = " ++ show _itemSeverity ++ ", " ++
                          "_itemThread = " ++ show _itemThread ++ ", " ++
                          "_itemHost = " ++ show _itemHost ++ ", " ++
                          "_itemProcess = " ++ show _itemProcess ++ ", " ++
                          "_itemPayload = " ++ show _itemPayload ++ ", " ++
                          "_itemMessage = " ++ show _itemMessage ++ ", " ++
                          "_itemTime = " ++ show _itemTime ++ ", " ++
                          "_itemNamespace = " ++ show _itemNamespace ++ ", " ++
                          "_itemLoc = " ++ show (LocShow <$> _itemLoc) ++ "}"


newtype LocShow = LocShow Loc


instance Show LocShow where
    show (LocShow Loc{..}) =
      "Loc {loc_filename = " ++ show loc_filename ++ ", " ++
           "loc_package = " ++ show loc_package ++ ", " ++
           "loc_module = " ++ show loc_module ++ ", " ++
           "loc_start = " ++ show loc_start ++ ", " ++
           "loc_end = " ++ show loc_end ++ "}"


instance ToJSON a => ToJSON (Item a) where
    toJSON Item{..} = A.object
      [ "app" A..= _itemApp
      , "env" A..= _itemEnv
      , "sev" A..= _itemSeverity
      , "thread" A..= getThreadIdText _itemThread
      , "host" A..= _itemHost
      , "pid" A..= ProcessIDJs _itemProcess
      , "data" A..= _itemPayload
      , "msg" A..= (B.toLazyText $ unLogStr _itemMessage)
      , "at" A..= _itemTime
      , "ns" A..= _itemNamespace
      , "loc" A..= fmap LocJs _itemLoc
      ]

newtype LocJs = LocJs { getLocJs :: Loc }


instance ToJSON LocJs where
    toJSON (LocJs (Loc fn p m (l, c) _)) = A.object
      [ "loc_fn" A..= fn
      , "loc_pkg" A..= p
      , "loc_mod" A..= m
      , "loc_ln" A..= l
      , "loc_col" A..= c
      ]


instance FromJSON LocJs where
    parseJSON = A.withObject "LocJs" parseLocJs
      where
        parseLocJs o = do
          fn <- o A..: "loc_fn"
          p <- o A..: "loc_pkg"
          m <- o A..: "loc_mod"
          l <- o A..: "loc_ln"
          c <- o A..: "loc_col"
          return $ LocJs $ Loc fn p m (l, c) (l, c)


instance FromJSON a => FromJSON (Item a) where
    parseJSON = A.withObject "Item" parseItem
      where
        parseItem o = Item
          <$> o A..: "app"
          <*> o A..: "env"
          <*> o A..: "sev"
          <*> o A..: "thread"
          <*> o A..: "host"
          <*> (getProcessIDJs <$> o A..: "pid")
          <*> o A..: "data"
          <*> o A..: "msg"
          <*> o A..: "at"
          <*> o A..: "ns"
          <*> (fmap getLocJs <$> o A..: "loc")


processIDToText :: ProcessID -> Text
processIDToText = toS . show


textToProcessID :: Text -> Maybe ProcessID
textToProcessID = readMay . toS


newtype ProcessIDJs = ProcessIDJs {
      getProcessIDJs :: ProcessID
    }


instance ToJSON ProcessIDJs where
    toJSON (ProcessIDJs p) = A.String (processIDToText p)


instance FromJSON ProcessIDJs where
    parseJSON = A.withText "ProcessID" parseProcessID
      where
        parseProcessID t = case textToProcessID t of
          Just p -> return $ ProcessIDJs p
          Nothing -> fail $ "Invalid ProcessIDJs " ++ toS t


-------------------------------------------------------------------------------
-- | Field selector by verbosity within JSON payload.
data PayloadSelection
    = AllKeys
    | SomeKeys [Text]
    deriving (Show, Eq)

instance Semigroup PayloadSelection where
  AllKeys <> _ = AllKeys
  _ <> AllKeys = AllKeys
  SomeKeys as <> SomeKeys bs = SomeKeys (as <> bs)


instance Monoid PayloadSelection where
    mempty = SomeKeys []
    mappend = (<>)


-------------------------------------------------------------------------------
-- | Katip requires JSON objects to be logged as context. This
-- typeclass provides a default instance which uses ToJSON and
-- produces an empty object if 'toJSON' results in any type other than
-- object. If you have a type you want to log that produces an Array
-- or Number for example, you'll want to write an explicit instance
-- here. You can trivially add a ToObject instance for something with
-- a ToJSON instance like:
--
-- > instance ToObject Foo
class ToObject a where
    toObject :: a -> A.Object
    default toObject :: ToJSON a => a -> A.Object
    toObject v = case toJSON v of
      A.Object o -> o
      _        -> mempty

instance ToObject ()
instance ToObject A.Object

-------------------------------------------------------------------------------
-- | Payload objects need instances of this class. LogItem makes it so
-- that you can have very verbose items getting logged with lots of
-- extra fields but under normal circumstances, if your scribe is
-- configured for a lower verbosity level, it will only log a
-- selection of those keys. Furthermore, each 'Scribe' can be
-- configured with a different 'Verbosity' level. You could even use
-- 'registerScribe', 'unregisterScribe', and 'clearScribes' to at
-- runtime swap out your existing scribes for more verbose debugging
-- scribes if you wanted to.
--
-- When defining 'payloadKeys', don't redundantly declare the same
-- keys for higher levels of verbosity. Each level of verbosity
-- automatically and recursively contains all keys from the level
-- before it.
class ToObject a => LogItem a where

    -- | List of keys in the JSON object that should be included in message.
    payloadKeys :: Verbosity -> a -> PayloadSelection


instance LogItem () where payloadKeys _ _ = SomeKeys []


data AnyLogPayload = forall a. ToJSON a => AnyLogPayload a

newtype SimpleLogPayload = SimpleLogPayload {
      unSimpleLogPayload :: [(Text, AnyLogPayload)]
    }

-------------------------------------------------------------------------------
-- | A built-in convenience log payload that won't log anything on 'V0',
-- but will log everything in any other level of verbosity. Intended
-- for easy in-line usage without having to define new log types.
--
-- Construct using 'sl' and combine multiple tuples using '<>' from
-- 'Monoid'.
instance ToJSON SimpleLogPayload where
    toJSON (SimpleLogPayload as) = object $ map go as
      where go (k, AnyLogPayload v) = k A..= v


instance ToObject SimpleLogPayload


instance LogItem SimpleLogPayload where
    payloadKeys V0 _ = SomeKeys []
    payloadKeys _ _ = AllKeys


instance Semigroup SimpleLogPayload where
  SimpleLogPayload a <> SimpleLogPayload b = SimpleLogPayload (a <> b)


instance Monoid SimpleLogPayload where
    mempty = SimpleLogPayload []
    mappend = (<>)


-------------------------------------------------------------------------------
-- | Construct a simple log from any JSON item.
sl :: ToJSON a => Text -> a -> SimpleLogPayload
sl a b = SimpleLogPayload [(a, AnyLogPayload b)]


-------------------------------------------------------------------------------
-- | Constrain payload based on verbosity. Backends should use this to
-- automatically bubble higher verbosity levels to lower ones.
payloadObject :: LogItem a => Verbosity -> a -> A.Object
payloadObject verb a = case FT.foldMap (flip payloadKeys a) [(V0)..verb] of
    AllKeys -> toObject a
    SomeKeys ks -> HM.filterWithKey (\ k _ -> k `FT.elem` ks) $ toObject a


-------------------------------------------------------------------------------
-- | Convert log item to its JSON representation while trimming its
-- payload based on the desired verbosity. Backends that push JSON
-- messages should use this to obtain their payload.
itemJson :: LogItem a => Verbosity -> Item a -> A.Value
itemJson verb a = toJSON $ a & itemPayload %~ payloadObject verb


-------------------------------------------------------------------------------
-- | Scribes are handlers of incoming items. Each registered scribe
-- knows how to push a log item somewhere.
--
-- = Guidelines for writing your own 'Scribe'
--
-- Scribes should always take a 'Severity' and 'Verbosity'.
--
-- Severity is used to *exclude log messages* that are < the provided
-- Severity. For instance, if the user passes InfoS, DebugS items
-- should be ignored. Katip provides the 'permitItem' utility for this.
--
-- Verbosity is used to select keys from the log item's payload. Each
-- 'LogItem' instance describes what keys should be retained for each
-- Verbosity level. Use the 'payloadObject' utility for extracting the keys
-- that should be permitted.
--
-- There is no built-in mechanism in katip for telling a scribe that
-- its time to shut down. 'unregisterScribe' merely drops it from the
-- 'LogEnv'. This means there are 2 ways to handle resources as a scribe:
--
-- 1. Pass in the resource when the scribe is created. Handle
-- allocation and release of the resource elsewhere. This is what the
-- Handle scribe does.
--
-- 2. Return a finalizing function that tells the scribe to shut
-- down. @katip-elasticsearch@'s @mkEsScribe@ returns a @IO (Scribe,
-- IO ())@. The finalizer will flush any queued log messages and shut
-- down gracefully before returning. This can be hooked into your
-- application's shutdown routine to ensure you never miss any log
-- messages on shutdown.
data Scribe = Scribe {
      liPush :: forall a. LogItem a => Item a -> IO ()
    }


instance Semigroup Scribe where
  (Scribe a) <> (Scribe b) = Scribe $ \ item -> do
    a item
    b item


instance Monoid Scribe where
    mempty = Scribe $ const $ return ()
    mappend = (<>)


-------------------------------------------------------------------------------
-- | Should this item be logged given the user's maximum severity?
permitItem :: Severity -> Item a -> Bool
permitItem sev i = _itemSeverity i >= sev


-------------------------------------------------------------------------------
data LogEnv = LogEnv {
      _logEnvHost    :: HostName
    , _logEnvPid     :: ProcessID
    , _logEnvApp     :: Namespace
    -- ^ Name of application. This will typically never change. This
    -- field gets prepended to the namespace of your individual log
    -- messages. For example, if your app is MyApp and you write a log
    -- using "logItem" and the namespace "WebServer", the final
    -- namespace will be "MyApp.WebServer"
    , _logEnvEnv     :: Environment
    , _logEnvTimer   :: IO UTCTime
    -- ^ Action to fetch the timestamp. You can use something like
    -- 'AutoUpdate' for high volume logs but note that this may cause
    -- some output forms to display logs out of order. Alternatively,
    -- you could just use 'getCurrentTime'.
    , _logEnvScribes :: M.Map Text Scribe
    }
makeLenses ''LogEnv


-------------------------------------------------------------------------------
-- | Create a reasonable default InitLogEnv. Uses an 'AutoUdate' with
-- the default settings as the timer. If you are concerned about
-- timestamp precision or event ordering in log outputs like
-- ElasticSearch, you should replace the timer with 'getCurrentTime'
initLogEnv
    :: Namespace
    -- ^ A base namespace for this application
    -> Environment
    -- ^ Current run environment (e.g. @prod@ vs. @devel@)
    -> IO LogEnv
initLogEnv an env = LogEnv
  <$> getHostName
  <*> getProcessID
  <*> pure an
  <*> pure env
  <*> mkAutoUpdate defaultUpdateSettings { updateAction = getCurrentTime }
  <*> pure mempty


-------------------------------------------------------------------------------
-- | Add a scribe to the list. All future log calls will go to this
-- scribe in addition to the others.
registerScribe
    :: Text
    -- ^ Name the scribe
    -> Scribe
    -> LogEnv
    -> LogEnv
registerScribe nm h = logEnvScribes %~ M.insert nm h


-------------------------------------------------------------------------------
-- | Remove a scribe from the list. All future log calls will no
-- longer use this scribe. If the given scribe doesn't exist, its a no-op.
unregisterScribe
    :: Text
    -- ^ Name of the scribe
    -> LogEnv
    -> LogEnv
unregisterScribe nm = logEnvScribes %~ M.delete nm


-------------------------------------------------------------------------------
-- | Unregister *all* scribes. Logs will go off into space from this
-- point onward until new scribes are added. Note that you could use
-- this with `local` if you're using a Reader based stack to
-- temporarily disable log output. See `katipNoLogging` for an
-- example.
clearScribes
    :: LogEnv
    -> LogEnv
clearScribes = logEnvScribes .~ mempty


-------------------------------------------------------------------------------
-- | Monads where katip logging actions can be performed. Katip is the
-- most basic logging monad. You will typically use this directly if
-- you either don't want to use namespaces/contexts heavily or if you
-- want to pass in specific contexts and/or namespaces at each log site.
--
-- For something more powerful, look at the docs for 'KatipContext',
-- which keeps a namespace and merged context. You can write simple
-- functions that add additional namespacing and merges additional
-- context on the fly.
class MonadIO m => Katip m where
    getLogEnv :: m LogEnv


instance Katip m => Katip (ReaderT s m) where
    getLogEnv = lift getLogEnv


instance Katip m => Katip (EitherT s m) where
    getLogEnv = lift getLogEnv

instance Katip m => Katip (ExceptT s m) where
    getLogEnv = lift getLogEnv

instance Katip m => Katip (MaybeT m) where
    getLogEnv = lift getLogEnv


instance Katip m => Katip (StateT s m) where
    getLogEnv = lift getLogEnv


instance (Katip m, Monoid s) => Katip (WriterT s m) where
    getLogEnv = lift getLogEnv

instance (Katip m) => Katip (ResourceT m) where
    getLogEnv = lift getLogEnv


-------------------------------------------------------------------------------
-- | A concrete monad you can use to run logging actions.
newtype KatipT m a = KatipT { unKatipT :: ReaderT LogEnv m a }
  deriving ( Functor, Applicative, Monad, MonadIO
           , MonadMask, MonadCatch, MonadThrow, MonadTrans, MonadBase b)


instance MonadIO m => Katip (KatipT m) where
    getLogEnv = KatipT ask


instance MonadTransControl KatipT where
    type StT (KatipT) a = a
    liftWith f = KatipT $ ReaderT $ \le -> f $ \t -> runKatipT le t
    restoreT = KatipT . ReaderT . const
    {-# INLINABLE liftWith #-}
    {-# INLINABLE restoreT #-}


instance (MonadBaseControl b m) => MonadBaseControl b (KatipT m) where
  type StM ((KatipT) m) a = ComposeSt (KatipT) m a
  liftBaseWith = defaultLiftBaseWith
  restoreM = defaultRestoreM


-------------------------------------------------------------------------------
-- | Execute 'KatipT' on a log env.
runKatipT :: LogEnv -> KatipT m a -> m a
runKatipT le (KatipT f) = runReaderT f le


-------------------------------------------------------------------------------
-- | Log with everything, including a source code location. This is
-- very low level and you typically can use 'logT' in its place.
logItem
    :: (A.Applicative m, LogItem a, Katip m)
    => a
    -> Namespace
    -> Maybe Loc
    -> Severity
    -> LogStr
    -> m ()
logItem a ns loc sev msg = do
    LogEnv{..} <- getLogEnv
    liftIO $ do
      item <- Item
        <$> pure _logEnvApp
        <*> pure _logEnvEnv
        <*> pure sev
        <*> (mkThreadIdText <$> myThreadId)
        <*> pure _logEnvHost
        <*> pure _logEnvPid
        <*> pure a
        <*> pure msg
        <*> _logEnvTimer
        <*> pure (_logEnvApp <> ns)
        <*> pure loc
      FT.forM_ (M.elems _logEnvScribes) $ \ (Scribe h) -> h item


-------------------------------------------------------------------------------
-- | Log with full context, but without any code location.
logF
  :: (Applicative m, LogItem a, Katip m)
  => a
  -- ^ Contextual payload for the log
  -> Namespace
  -- ^ Specific namespace of the message.
  -> Severity
  -- ^ Severity of the message
  -> LogStr
  -- ^ The log message
  -> m ()
logF a ns sev msg = logItem a ns Nothing sev msg



-------------------------------------------------------------------------------
-- | Perform an action while logging any exceptions that may occur.
-- Inspired by 'onException`.
--
-- >>>> logException () mempty ErrorS (error "foo")
logException
    :: (Katip m, LogItem a, MonadCatch m, Applicative m)
    => a                        -- ^ Log context
    -> Namespace                -- ^ Namespace
    -> Severity                 -- ^ Severity
    -> m b                      -- ^ Main action being run
    -> m b
logException a ns sev action = action `catchAll` \e -> f e >> throwM e
  where
    f e = logF a ns sev (msg e)
    msg e = ls (T.pack "An exception has occured: ") <> showLS e


-------------------------------------------------------------------------------
-- | Log a message without any payload/context or code location.
logMsg
    :: (Applicative m, Katip m)
    => Namespace
    -> Severity
    -> LogStr
    -> m ()
logMsg ns sev msg = logF () ns sev msg


instance TH.Lift Namespace where
    lift (Namespace xs) =
      let xs' = map T.unpack xs
      in  [| Namespace (map T.pack xs') |]


instance TH.Lift Verbosity where
    lift V0 = [| V0 |]
    lift V1 = [| V1 |]
    lift V2 = [| V2 |]
    lift V3 = [| V3 |]


instance TH.Lift Severity where
    lift DebugS = [| DebugS |]
    lift InfoS  = [| InfoS |]
    lift NoticeS  = [| NoticeS |]
    lift WarningS  = [| WarningS |]
    lift ErrorS  = [| ErrorS |]
    lift CriticalS  = [| CriticalS |]
    lift AlertS  = [| AlertS |]
    lift EmergencyS  = [| EmergencyS |]


-- | Lift a location into an Exp.
liftLoc :: Loc -> Q Exp
liftLoc (Loc a b c (d1, d2) (e1, e2)) = [|Loc
    $(TH.lift a)
    $(TH.lift b)
    $(TH.lift c)
    ($(TH.lift d1), $(TH.lift d2))
    ($(TH.lift e1), $(TH.lift e2))
    |]


-------------------------------------------------------------------------------
-- | For use when you want to include location in your logs. This will
-- fill the 'Maybe Loc' gap in 'logF' of this module, and relies on implicit
-- callstacks when available (GHC > 7.8).
#if MIN_VERSION_base(4, 8, 0)
getLoc :: (?loc :: CallStack) => Maybe Loc
getLoc = case getCallStack ?loc of
  [] -> Nothing
  xs -> Just . toLoc . last $ xs
  where
    toLoc :: (String, SrcLoc) -> Loc
    toLoc (_, l) = Loc {
        loc_filename = srcLocFile l
      , loc_package  = srcLocPackage l
      , loc_module   = srcLocModule l
      , loc_start    = (srcLocStartLine l, srcLocStartCol l)
      , loc_end      = (srcLocEndLine   l, srcLocEndCol   l)
      }
#else
getLoc :: Maybe Loc
getLoc = Nothing
#endif


-------------------------------------------------------------------------------
-- Like `getLoc`, but uses template-haskell and works with older versions of
-- the compiler (GHC 7.8 or older).
getLocTH :: ExpQ
getLocTH = [| $(location >>= liftLoc) |]


-------------------------------------------------------------------------------
-- | 'Loc'-tagged logging when using template-haskell.
--
-- @$(logT) obj mempty InfoS "Hello world"@
logT :: ExpQ
logT = [| \ a ns sev msg -> logItem a ns (Just $(getLocTH)) sev msg |]


-------------------------------------------------------------------------------
-- | 'Loc'-tagged logging using implicit-callstacks when available.
--
-- This function does not require template-haskell as it
-- automatically uses <https://hackage.haskell.org/package/base-4.8.2.0/docs/GHC-Stack.html#v:getCallStack implicit-callstacks>
-- when the code is compiled using GHC > 7.8. Using an older version of the
-- compiler will result in the emission of a log line without any location information,
-- so be aware of it. Users using GHC <= 7.8 may want to use the template-haskell function
-- `logT` for maximum compatibility.
--
-- @logLoc obj mempty InfoS "Hello world"@
logLoc :: (Applicative m, LogItem a, Katip m)
       => a
       -> Namespace
       -> Severity
       -> LogStr
       -> m ()
logLoc a ns = logItem a ns getLoc


-- taken from the file-location package
-- turn the TH Loc loaction information into a human readable string
-- leaving out the loc_end parameter
locationToString :: Loc -> String
locationToString loc = (loc_package loc) ++ ':' : (loc_module loc) ++
  ' ' : (loc_filename loc) ++ ':' : (line loc) ++ ':' : (char loc)
  where
    line = show . fst . loc_start
    char = show . snd . loc_start
