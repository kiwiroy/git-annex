{- Standard git remotes.
 -
 - Copyright 2011 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Remote.Git (remote) where

import Control.Exception.Extensible
import qualified Data.Map as M

import Common.Annex
import Utility.CopyFile
import Utility.RsyncFile
import Annex.Ssh
import Types.Remote
import qualified Git
import qualified Annex
import Annex.UUID
import qualified Annex.Content
import qualified Annex.Branch
import qualified Utility.Url as Url
import Utility.TempFile
import Config
import Init

remote :: RemoteType Annex
remote = RemoteType {
	typename = "git",
	enumerate = list,
	generate = gen,
	setup = error "not supported"
}

list :: Annex [Git.Repo]
list = do
	c <- fromRepo Git.configMap
	mapM (tweakurl c) =<< fromRepo Git.remotes
	where
		annexurl n = "remote." ++ n ++ ".annexurl"
		tweakurl c r = do
			let n = fromJust $ Git.repoRemoteName r
			case M.lookup (annexurl n) c of
				Nothing -> return r
				Just url -> Git.repoRemoteNameSet n <$>
					inRepo (Git.genRemote url)

gen :: Git.Repo -> UUID -> Maybe RemoteConfig -> Annex (Remote Annex)
gen r u _ = do
 	{- It's assumed to be cheap to read the config of non-URL remotes,
	 - so this is done each time git-annex is run. Conversely,
	 - the config of an URL remote is only read when there is no
	 - cached UUID value. -}
	let cheap = not $ Git.repoIsUrl r
	notignored <- repoNotIgnored r
	r' <- case (cheap, notignored, u) of
		(_, False, _) -> return r
		(True, _, _) -> tryGitConfigRead r
		(False, _, NoUUID) -> tryGitConfigRead r
		_ -> return r

	u' <- getRepoUUID r'

	let defcst = if cheap then cheapRemoteCost else expensiveRemoteCost
	cst <- remoteCost r' defcst

	return Remote {
		uuid = u',
		cost = cst,
		name = Git.repoDescribe r',
		storeKey = copyToRemote r',
		retrieveKeyFile = copyFromRemote r',
		removeKey = dropKey r',
		hasKey = inAnnex r',
		hasKeyCheap = cheap,
		config = Nothing,
		repo = r'
	}

{- Tries to read the config for a specified remote, updates state, and
 - returns the updated repo. -}
tryGitConfigRead :: Git.Repo -> Annex Git.Repo
tryGitConfigRead r 
	| not $ M.null $ Git.configMap r = return r -- already read
	| Git.repoIsSsh r = store $ onRemote r (pipedconfig, r) "configlist" []
	| Git.repoIsHttp r = store $ safely geturlconfig
	| Git.repoIsUrl r = return r
	| otherwise = store $ safely $ onLocal r $ do 
		ensureInitialized
		Annex.getState Annex.repo
	where
		-- Reading config can fail due to IO error or
		-- for other reasons; catch all possible exceptions.
		safely a = do
			result <- liftIO (try a :: IO (Either SomeException Git.Repo))
			case result of
				Left _ -> return r
				Right r' -> return r'

		pipedconfig cmd params = safely $
			pOpen ReadFromPipe cmd (toCommand params) $
				Git.hConfigRead r

		geturlconfig = do
			s <- Url.get (Git.repoLocation r ++ "/config")
			withTempFile "git-annex.tmp" $ \tmpfile h -> do
				hPutStr h s
				hClose h
				pOpen ReadFromPipe "git" ["config", "--list", "--file", tmpfile] $
					Git.hConfigRead r

		store a = do
			r' <- a
			g <- gitRepo
			let l = Git.remotes g
			let g' = Git.remotesAdd g $ exchange l r'
			Annex.changeState $ \s -> s { Annex.repo = g' }
			return r'

		exchange [] _ = []
		exchange (old:ls) new =
			if Git.repoRemoteName old == Git.repoRemoteName new
				then new : exchange ls new
				else old : exchange ls new

{- Checks if a given remote has the content for a key inAnnex.
 - If the remote cannot be accessed, or if it cannot determine
 - whether it has the content, returns a Left error message.
 -}
inAnnex :: Git.Repo -> Key -> Annex (Either String Bool)
inAnnex r key
	| Git.repoIsHttp r = checkhttp
	| Git.repoIsUrl r = checkremote
	| otherwise = checklocal
	where
		checkhttp = liftIO $ go undefined $ keyUrls r key
			where
				go e [] = return $ Left e
				go _ (u:us) = do
					res <- catchMsgIO $ Url.exists u
					case res of
						Left e -> go e us
						v -> return v
		checkremote = do
			showAction $ "checking " ++ Git.repoDescribe r
			onRemote r (check, unknown) "inannex" [Param (show key)]
			where
				check c p = dispatch <$> safeSystem c p
				dispatch ExitSuccess = Right True
				dispatch (ExitFailure 1) = Right False
				dispatch _ = unknown
		checklocal = dispatch <$> check
			where
				check = liftIO $ catchMsgIO $ onLocal r $
					Annex.Content.inAnnexSafe key
				dispatch (Left e) = Left e
				dispatch (Right (Just b)) = Right b
				dispatch (Right Nothing) = unknown
		unknown = Left $ "unable to check " ++ Git.repoDescribe r

{- Runs an action on a local repository inexpensively, by making an annex
 - monad using that repository. -}
onLocal :: Git.Repo -> Annex a -> IO a
onLocal r a = do
	-- Avoid re-reading the repository's configuration if it was
	-- already read.
	state <- if M.null $ Git.configMap r
		then Annex.new r
		else return $ Annex.newState r
	Annex.eval state $ do
		-- No need to update the branch; its data is not used
		-- for anything onLocal is used to do.
		Annex.Branch.disableUpdate
		ret <- a
		liftIO Git.reap
		return ret

keyUrls :: Git.Repo -> Key -> [String]
keyUrls r key = map tourl (annexLocations key)
	where
		tourl l = Git.repoLocation r ++ "/" ++ l

dropKey :: Git.Repo -> Key -> Annex Bool
dropKey r key
	| Git.repoIsHttp r = error "dropping from http repo not supported"
	| otherwise = onRemote r (boolSystem, False) "dropkey"
		[ Params "--quiet --force"
		, Param $ show key
		]

{- Tries to copy a key's content from a remote's annex to a file. -}
copyFromRemote :: Git.Repo -> Key -> FilePath -> Annex Bool
copyFromRemote r key file
	| not $ Git.repoIsUrl r = do
		params <- rsyncParams r
		loc <- liftIO $ gitAnnexLocation key r
		rsyncOrCopyFile params loc file
	| Git.repoIsSsh r = rsyncHelper =<< rsyncParamsRemote r True key file
	| Git.repoIsHttp r = liftIO $ downloadurls $ keyUrls r key
	| otherwise = error "copying from non-ssh, non-http repo not supported"
	where
		downloadurls us = untilTrue us $ \u -> Url.download u file

{- Tries to copy a key's content to a remote's annex. -}
copyToRemote :: Git.Repo -> Key -> Annex Bool
copyToRemote r key
	| not $ Git.repoIsUrl r = do
		keysrc <- inRepo $ gitAnnexLocation key
		params <- rsyncParams r
		-- run copy from perspective of remote
		liftIO $ onLocal r $ do
			ensureInitialized
			ok <- Annex.Content.getViaTmp key $
				rsyncOrCopyFile params keysrc
			Annex.Content.saveState
			return ok
	| Git.repoIsSsh r = do
		keysrc <- inRepo $ gitAnnexLocation key
		rsyncHelper =<< rsyncParamsRemote r False key keysrc
	| otherwise = error "copying to non-ssh repo not supported"

rsyncHelper :: [CommandParam] -> Annex Bool
rsyncHelper p = do
	showOutput -- make way for progress bar
	res <- liftIO $ rsync p
	if res
		then return res
		else do
			showLongNote "rsync failed -- run git annex again to resume file transfer"
			return res

{- Copys a file with rsync unless both locations are on the same
 - filesystem. Then cp could be faster. -}
rsyncOrCopyFile :: [CommandParam] -> FilePath -> FilePath -> Annex Bool
rsyncOrCopyFile rsyncparams src dest = do
	ss <- liftIO $ getFileStatus $ parentDir src
	ds <- liftIO $ getFileStatus $ parentDir dest
	if deviceID ss == deviceID ds
		then liftIO $ copyFileExternal src dest
		else rsyncHelper $ rsyncparams ++ [Param src, Param dest]

{- Generates rsync parameters that ssh to the remote and asks it
 - to either receive or send the key's content. -}
rsyncParamsRemote :: Git.Repo -> Bool -> Key -> FilePath -> Annex [CommandParam]
rsyncParamsRemote r sending key file = do
	Just (shellcmd, shellparams) <- git_annex_shell r
		(if sending then "sendkey" else "recvkey")
		[ Param $ show key
		-- Command is terminated with "--", because
		-- rsync will tack on its own options afterwards,
		-- and they need to be ignored.
		, Param "--"
		]
	-- Convert the ssh command into rsync command line.
	let eparam = rsyncShell (Param shellcmd:shellparams)
	o <- rsyncParams r
	if sending
		then return $ o ++ eparam ++ [dummy, File file]
		else return $ o ++ eparam ++ [File file, dummy]
	where
		-- the rsync shell parameter controls where rsync
		-- goes, so the source/dest parameter can be a dummy value,
		-- that just enables remote rsync mode.
		dummy = Param ":"

rsyncParams :: Git.Repo -> Annex [CommandParam]
rsyncParams r = do
	o <- getConfig r "rsync-options" ""
	return $ options ++ map Param (words o)
	where
 		-- --inplace to resume partial files
		options = [Params "-p --progress --inplace"]
