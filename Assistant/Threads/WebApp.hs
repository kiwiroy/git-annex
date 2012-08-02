{- git-annex assistant webapp thread
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE TypeFamilies, QuasiQuotes, MultiParamTypeClasses, TemplateHaskell, OverloadedStrings, RankNTypes #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Assistant.Threads.WebApp where

import Assistant.Common
import Assistant.WebApp
import Assistant.WebApp.DashBoard
import Assistant.WebApp.SideBar
import Assistant.WebApp.Notifications
import Assistant.WebApp.Configurators
import Assistant.WebApp.Documentation
import Assistant.ThreadedMonad
import Assistant.DaemonStatus
import Assistant.TransferQueue
import Utility.WebApp
import Utility.FileMode
import Utility.TempFile
import Git

import Yesod
import Yesod.Static
import Network.Socket (PortNumber)
import Data.Text (pack, unpack)

thisThread :: String
thisThread = "WebApp"

mkYesodDispatch "WebApp" $(parseRoutesFile "Assistant/WebApp/routes")

type Url = String

webAppThread 
	:: (Maybe ThreadState) 
	-> DaemonStatusHandle
	-> TransferQueue
	-> Maybe (IO String)
	-> Maybe (Url -> FilePath -> IO ())
	-> IO ()
webAppThread mst dstatus transferqueue postfirstrun onstartup = do
	webapp <- WebApp
		<$> pure mst
		<*> pure dstatus
		<*> pure transferqueue
		<*> (pack <$> genRandomToken)
		<*> getreldir mst
		<*> pure $(embed "static")
		<*> newWebAppState
		<*> pure postfirstrun
	app <- toWaiAppPlain webapp
	app' <- ifM debugEnabled
		( return $ httpDebugLogger app
		, return app
		)
	runWebApp app' $ \port -> case mst of
		Nothing -> withTempFile "webapp.html" $ \tmpfile _ -> go port webapp tmpfile
		Just st -> go port webapp =<< runThreadState st (fromRepo gitAnnexHtmlShim)
	where
		getreldir Nothing = return Nothing
		getreldir (Just st) = Just <$>
			(relHome =<< absPath
				=<< runThreadState st (fromRepo repoPath))
		go port webapp htmlshim = do
			writeHtmlShim webapp port htmlshim
			maybe noop (\a -> a (myUrl webapp port "/") htmlshim) onstartup

{- Creates a html shim file that's used to redirect into the webapp,
 - to avoid exposing the secretToken when launching the web browser. -}
writeHtmlShim :: WebApp -> PortNumber -> FilePath -> IO ()
writeHtmlShim webapp port file = do
	debug thisThread ["running on port", show port]
	viaTmp go file $ genHtmlShim webapp port
	where
		go tmpfile content = do
			h <- openFile tmpfile WriteMode
			modifyFileMode tmpfile $ removeModes [groupReadMode, otherReadMode]
			hPutStr h content
			hClose h

{- TODO: generate this static file using Yesod. -}
genHtmlShim :: WebApp -> PortNumber -> String
genHtmlShim webapp port = unlines
	[ "<html>"
	, "<head>"
	, "<title>Starting webapp...</title>"
	, "<meta http-equiv=\"refresh\" content=\"0; URL="++url++"\">"
	, "<body>"
	, "<p>"
	, "<a href=\"" ++ url ++ "\">Starting webapp...</a>"
	, "</p>"
	, "</body>"
	, "</html>"
	]
	where
		url = myUrl webapp port "/"

myUrl :: WebApp -> PortNumber -> FilePath -> Url
myUrl webapp port page = "http://localhost:" ++ show port ++ page ++
	"?auth=" ++ unpack (secretToken webapp)
