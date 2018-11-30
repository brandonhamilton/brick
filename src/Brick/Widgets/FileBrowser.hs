{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
module Brick.Widgets.FileBrowser
  ( FileBrowser(fileBrowserSelection, fileBrowserWorkingDirectory, fileBrowserEntryFilter)
  , FileInfo(..)
  , FileType(..)
  , newFileBrowser
  , setCurrentDirectory
  , renderFileBrowser
  , fileBrowserCursor
  , handleFileBrowserEvent
  , updateFileBrowserSearch
  , fileBrowserIsSearching

  -- * Lenses
  , fileBrowserWorkingDirectoryL
  , fileBrowserSelectionL
  , fileBrowserEntryFilterL
  , fileInfoFilenameL
  , fileInfoFileSizeL
  , fileInfoSanitizedFilenameL
  , fileInfoFilePathL
  , fileInfoFileTypeL

  -- * Attributes
  , fileBrowserAttr
  , fileBrowserCurrentDirectoryAttr
  , fileBrowserSelectionInfoAttr
  , fileBrowserDirectoryAttr
  , fileBrowserBlockDeviceAttr
  , fileBrowserRegularFileAttr
  , fileBrowserCharacterDeviceAttr
  , fileBrowserNamedPipeAttr
  , fileBrowserSymbolicLinkAttr
  , fileBrowserSocketAttr

  -- * Filters
  , fileTypeMatch
  )
where

import Control.Monad (forM)
import Control.Monad.IO.Class (liftIO)
import Data.Char (toLower, isPrint)
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Text as T
#if !(MIN_VERSION_base(4,11,0))
import Data.Monoid
#endif
import Data.Int (Int64)
import Data.List (sortBy)
import qualified Data.Vector as V
import Lens.Micro
import qualified Graphics.Vty as Vty
import qualified System.Directory as D
import qualified System.Posix.Files as U
import qualified System.Posix.Types as U
import qualified System.FilePath as FP
import Text.Printf (printf)

import Brick.Types
import Brick.AttrMap (AttrName)
import Brick.Widgets.Core
import Brick.Widgets.List

data FileBrowser n =
    FileBrowser { fileBrowserWorkingDirectory :: FilePath
                , fileBrowserEntries :: List n FileInfo
                , fileBrowserLatestResults :: [FileInfo]
                , fileBrowserName :: n
                , fileBrowserSelection :: Maybe FileInfo
                , fileBrowserEntryFilter :: Maybe (FileInfo -> Bool)
                , fileBrowserSearchString :: Maybe T.Text
                }

data FileInfo =
    FileInfo { fileInfoFilename :: String
             , fileInfoSanitizedFilename :: String
             , fileInfoFilePath :: FilePath
             , fileInfoFileType :: Maybe FileType
             , fileInfoFileSize :: Int64
             }
             deriving (Show, Eq, Read)

data FileType =
    RegularFile
    | BlockDevice
    | CharacterDevice
    | NamedPipe
    | Directory
    | SymbolicLink
    | Socket
    deriving (Read, Show, Eq)

suffixLenses ''FileBrowser
suffixLenses ''FileInfo

newFileBrowser :: n -> Maybe FilePath -> IO (FileBrowser n)
newFileBrowser name mCwd = do
    initialCwd <- case mCwd of
        Just path -> return path
        Nothing -> D.getCurrentDirectory

    let b = FileBrowser { fileBrowserWorkingDirectory = initialCwd
                        , fileBrowserEntries = list name mempty 1
                        , fileBrowserLatestResults = mempty
                        , fileBrowserName = name
                        , fileBrowserSelection = Nothing
                        , fileBrowserEntryFilter = Nothing
                        , fileBrowserSearchString = Nothing
                        }

    setCurrentDirectory initialCwd b

setCurrentDirectory :: FilePath -> FileBrowser n -> IO (FileBrowser n)
setCurrentDirectory path b = do
    let match = fromMaybe (const True) (b^.fileBrowserEntryFilterL)
    entries <- filter match <$> entriesForDirectory path
    let b' = setEntries entries b
    return b' { fileBrowserWorkingDirectory = path }

setEntries :: [FileInfo] -> FileBrowser n -> FileBrowser n
setEntries es b =
    applySearch $ b & fileBrowserLatestResultsL .~ es

fileBrowserIsSearching :: FileBrowser n -> Bool
fileBrowserIsSearching b = isJust $ b^.fileBrowserSearchStringL

updateFileBrowserSearch :: (Maybe T.Text -> Maybe T.Text) -> FileBrowser n -> FileBrowser n
updateFileBrowserSearch f b =
    let old = b^.fileBrowserSearchStringL
        new = f $ b^.fileBrowserSearchStringL
        oldLen = maybe 0 T.length old
        newLen = maybe 0 T.length new
    in if old == new
       then b
       else if oldLen == newLen
            -- This case avoids a list rebuild and cursor position reset
            -- when the search state isn't *really* changing.
            then b & fileBrowserSearchStringL .~ new
            else applySearch $ b & fileBrowserSearchStringL .~ new

applySearch :: FileBrowser n -> FileBrowser n
applySearch b =
    let searchMatch = maybe (const True)
                            (\search i -> (T.toLower search `T.isInfixOf` (T.pack $ toLower <$> fileInfoSanitizedFilename i)))
                            (b^.fileBrowserSearchStringL)
        matching = filter searchMatch $ b^.fileBrowserLatestResultsL
    in b { fileBrowserEntries = list (b^.fileBrowserNameL) (V.fromList matching) 1 }

prettyFileSize :: Int64 -> T.Text
prettyFileSize i
    | i >= 2 ^ (40::Int64) = T.pack $ format (i `divBy` (2 ** 40)) <> "T"
    | i >= 2 ^ (30::Int64) = T.pack $ format (i `divBy` (2 ** 30)) <> "G"
    | i >= 2 ^ (20::Int64) = T.pack $ format (i `divBy` (2 ** 20)) <> "M"
    | i >= 2 ^ (10::Int64) = T.pack $ format (i `divBy` (2 ** 10)) <> "K"
    | otherwise    = T.pack $ show i <> " bytes"
    where
        format = printf "%0.1f"
        divBy :: Int64 -> Double -> Double
        divBy a b = ((fromIntegral a) :: Double) / b

entriesForDirectory :: FilePath -> IO [FileInfo]
entriesForDirectory rawPath = do
    path <- D.makeAbsolute rawPath

    -- Get all entries except "." and "..", then sort them
    dirContents <- D.listDirectory path

    let addParent = if path == "/"
                    then id
                    else (parentDir :)
        parentDir = ".."
        allFiles = addParent dirContents

    infos <- forM allFiles $ \f -> do
        filePath <- D.canonicalizePath $ path FP.</> f
        status <- U.getFileStatus filePath
        let U.COff sz = U.fileSize status
        return FileInfo { fileInfoFilename = f
                        , fileInfoFilePath = filePath
                        , fileInfoSanitizedFilename = sanitizeFilename f
                        , fileInfoFileType = fileTypeFromStatus status
                        , fileInfoFileSize = sz
                        }

    let dirsFirst a b = if fileInfoFileType a == Just Directory &&
                           fileInfoFileType b == Just Directory
                        then compare (toLower <$> fileInfoFilename a)
                                     (toLower <$> fileInfoFilename b)
                        else if fileInfoFileType a == Just Directory &&
                                fileInfoFileType b /= Just Directory
                             then LT
                             else if fileInfoFileType b == Just Directory &&
                                     fileInfoFileType a /= Just Directory
                                  then GT
                                  else compare (toLower <$> fileInfoFilename a)
                                               (toLower <$> fileInfoFilename b)

        allEntries = sortBy dirsFirst infos

    return allEntries

fileTypeFromStatus :: U.FileStatus -> Maybe FileType
fileTypeFromStatus s =
    if | U.isBlockDevice s     -> Just BlockDevice
       | U.isCharacterDevice s -> Just CharacterDevice
       | U.isNamedPipe s       -> Just NamedPipe
       | U.isRegularFile s     -> Just RegularFile
       | U.isDirectory s       -> Just Directory
       | U.isSocket s          -> Just Socket
       | U.isSymbolicLink s    -> Just SymbolicLink
       | otherwise             -> Nothing

fileBrowserCursor :: FileBrowser n -> Maybe FileInfo
fileBrowserCursor b = snd <$> listSelectedElement (b^.fileBrowserEntriesL)

handleFileBrowserEvent :: (Ord n) => Vty.Event -> FileBrowser n -> EventM n (FileBrowser n)
handleFileBrowserEvent e b =
    if fileBrowserIsSearching b
    then handleFileBrowserEventSearching e b
    else handleFileBrowserEventNormal e b

safeInit :: T.Text -> T.Text
safeInit t | T.length t == 0 = t
           | otherwise = T.init t

handleFileBrowserEventSearching :: (Ord n) => Vty.Event -> FileBrowser n -> EventM n (FileBrowser n)
handleFileBrowserEventSearching e b =
    case e of
        Vty.EvKey (Vty.KChar 'c') [Vty.MCtrl] ->
            return $ updateFileBrowserSearch (const Nothing) b
        Vty.EvKey Vty.KEsc [] ->
            return $ updateFileBrowserSearch (const Nothing) b
        Vty.EvKey Vty.KBS [] ->
            return $ updateFileBrowserSearch (fmap safeInit) b
        Vty.EvKey Vty.KEnter [] ->
            maybeSelectCurrentEntry b
        Vty.EvKey (Vty.KChar c) [] ->
            return $ updateFileBrowserSearch (fmap (flip T.snoc c)) b
        _ ->
            handleEventLensed b fileBrowserEntriesL handleListEvent e

handleFileBrowserEventNormal :: (Ord n) => Vty.Event -> FileBrowser n -> EventM n (FileBrowser n)
handleFileBrowserEventNormal e b =
    case e of
        Vty.EvKey (Vty.KChar '/') [] ->
            -- Begin file search
            return $ updateFileBrowserSearch (const $ Just "") b
        Vty.EvKey Vty.KEnter [] ->
            -- Select file or enter directory
            maybeSelectCurrentEntry b
        _ ->
            -- Otherwise, delegate event to entry list
            handleEventLensed b fileBrowserEntriesL handleListEvent e

maybeSelectCurrentEntry :: FileBrowser n -> EventM n (FileBrowser n)
maybeSelectCurrentEntry b =
    case fileBrowserCursor b of
        Nothing -> return b
        Just entry ->
            case fileInfoFileType entry of
                Just Directory -> liftIO $ setCurrentDirectory (fileInfoFilePath entry) b
                _ -> return $ b & fileBrowserSelectionL .~ Just entry

renderFileBrowser :: (Show n, Ord n) => Bool -> FileBrowser n -> Widget n
renderFileBrowser foc b =
    let maxFilenameLength = maximum $ (length . fileInfoFilename) <$> (b^.fileBrowserEntriesL)
        cwdHeader = padRight Max $
                    str $ sanitizeFilename $ fileBrowserWorkingDirectory b
        selInfo = case listSelectedElement (b^.fileBrowserEntriesL) of
            Nothing -> vLimit 1 $ fill ' '
            Just (_, i) -> padRight Max $ selInfoFor i
        fileTypeLabel Nothing = "unknown"
        fileTypeLabel (Just t) =
            case t of
                RegularFile -> "file"
                BlockDevice -> "block device"
                CharacterDevice -> "character device"
                NamedPipe -> "pipe"
                Directory -> "directory"
                SymbolicLink -> "symbolic link"
                Socket -> "socket"
        selInfoFor i =
            let maybeSize = if fileInfoFileType i == Just RegularFile
                            then ", " <> prettyFileSize (fileInfoFileSize i)
                            else ""
            in txt $ (T.pack $ fileInfoSanitizedFilename i) <> ": " <>
                     fileTypeLabel (fileInfoFileType i) <> maybeSize
        maybeSearchInfo = case b^.fileBrowserSearchStringL of
            Nothing -> emptyWidget
            Just s -> padRight Max $
                      txt "Search: " <+>
                      showCursor (b^.fileBrowserNameL) (Location (T.length s, 0)) (txt s)

    in withDefAttr fileBrowserAttr $
       vBox [ withDefAttr fileBrowserCurrentDirectoryAttr cwdHeader
            , renderList (renderFileInfo foc maxFilenameLength) foc (b^.fileBrowserEntriesL)
            , maybeSearchInfo
            , withDefAttr fileBrowserSelectionInfoAttr selInfo
            ]

renderFileInfo :: Bool -> Int -> Bool -> FileInfo -> Widget n
renderFileInfo foc maxLen sel info =
    (if foc
     then (if sel then forceAttr listSelectedFocusedAttr else id)
     else (if sel then forceAttr listSelectedAttr else id)) $
    padRight Max body
    where
        addAttr = maybe id (withDefAttr . attrForFileType) (fileInfoFileType info)
        body = addAttr (hLimit (maxLen + 1) $ padRight Max $ str $ fileInfoSanitizedFilename info <> suffix)
        suffix = if fileInfoFileType info == Just Directory
                 then "/"
                 else ""

-- | Sanitize a filename for terminal display, replacing non-printable
-- characters with '?'.
sanitizeFilename :: String -> String
sanitizeFilename = fmap toPrint
    where
        toPrint c | isPrint c = c
                  | otherwise = '?'

attrForFileType :: FileType -> AttrName
attrForFileType RegularFile = fileBrowserRegularFileAttr
attrForFileType BlockDevice = fileBrowserBlockDeviceAttr
attrForFileType CharacterDevice = fileBrowserCharacterDeviceAttr
attrForFileType NamedPipe = fileBrowserNamedPipeAttr
attrForFileType Directory = fileBrowserDirectoryAttr
attrForFileType SymbolicLink = fileBrowserSymbolicLinkAttr
attrForFileType Socket = fileBrowserSocketAttr

fileBrowserAttr :: AttrName
fileBrowserAttr = "fileBrowser"

fileBrowserCurrentDirectoryAttr :: AttrName
fileBrowserCurrentDirectoryAttr = fileBrowserAttr <> "currentDirectory"

fileBrowserSelectionInfoAttr :: AttrName
fileBrowserSelectionInfoAttr = fileBrowserAttr <> "selectionInfo"

fileBrowserDirectoryAttr :: AttrName
fileBrowserDirectoryAttr = fileBrowserAttr <> "directory"

fileBrowserBlockDeviceAttr :: AttrName
fileBrowserBlockDeviceAttr = fileBrowserAttr <> "block"

fileBrowserRegularFileAttr :: AttrName
fileBrowserRegularFileAttr = fileBrowserAttr <> "regular"

fileBrowserCharacterDeviceAttr :: AttrName
fileBrowserCharacterDeviceAttr = fileBrowserAttr <> "char"

fileBrowserNamedPipeAttr :: AttrName
fileBrowserNamedPipeAttr = fileBrowserAttr <> "pipe"

fileBrowserSymbolicLinkAttr :: AttrName
fileBrowserSymbolicLinkAttr = fileBrowserAttr <> "symlink"

fileBrowserSocketAttr :: AttrName
fileBrowserSocketAttr = fileBrowserAttr <> "socket"

fileTypeMatch :: [FileType] -> FileInfo -> Bool
fileTypeMatch tys i = maybe False (`elem` tys) $ fileInfoFileType i
