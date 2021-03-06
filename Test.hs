{- git-annex test suite
 -
 - Copyright 2010-2013 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE CPP #-}

module Test where

import Test.Tasty
import Test.Tasty.Runners
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck
import Test.Tasty.Ingredients.Rerun
import Data.Monoid

import Options.Applicative hiding (command)
import qualified Data.Map as M
import qualified Text.JSON

import Common

import qualified Utility.SafeCommand
import qualified Annex
import qualified Annex.UUID
import qualified Backend
import qualified Git.CurrentRepo
import qualified Git.Filename
import qualified Git.Construct
import qualified Git.Types
import qualified Git.Ref
import qualified Git.LsTree
import qualified Git.FilePath
import qualified Locations
import qualified Types.KeySource
import qualified Types.Backend
import qualified Types.TrustLevel
import qualified Types
import qualified Logs.MapLog
import qualified Logs.Trust
import qualified Logs.Remote
import qualified Logs.Unused
import qualified Logs.Transfer
import qualified Logs.Presence
import qualified Types.MetaData
import qualified Remote
import qualified Types.Key
import qualified Types.Messages
import qualified Config
import qualified Config.Cost
import qualified Crypto
import qualified Annex.Init
import qualified Annex.CatFile
import qualified Annex.View
import qualified Annex.View.ViewedFile
import qualified Logs.View
import qualified Utility.Path
import qualified Utility.FileMode
import qualified Build.SysConfig
import qualified Utility.Format
import qualified Utility.Verifiable
import qualified Utility.Process
import qualified Utility.Misc
import qualified Utility.InodeCache
import qualified Utility.Env
import qualified Utility.Matcher
import qualified Utility.Exception
import qualified Utility.Hash
import qualified Utility.Scheduled
import qualified Utility.HumanTime
import qualified Utility.ThreadScheduler
import qualified Utility.Base64
import qualified Command.Uninit
import qualified CmdLine.GitAnnex as GitAnnex
#ifndef mingw32_HOST_OS
import qualified Remote.Helper.Encryptable
import qualified Types.Crypto
import qualified Utility.Gpg
#endif
import qualified Messages

main :: [String] -> IO ()
main ps = do
	Messages.enableDebugOutput
	let tests = testGroup "Tests"
		-- Test both direct and indirect mode.
		-- Windows is only going to use direct mode,
		-- so don't test twice.
		[ properties
#ifndef mingw32_HOST_OS
		, withTestEnv True $ unitTests "(direct)"
		, withTestEnv False $ unitTests "(indirect)"
#else
		, withTestEnv False $ unitTests ""
#endif
		]

	-- Can't use tasty's defaultMain because one of the command line
	-- parameters is "test".
	let pinfo = info (helper <*> suiteOptionParser ingredients tests)
		( fullDesc <> header "Builtin test suite" )
	opts <- parseOpts (prefs idm) pinfo ps
	case tryIngredients ingredients opts tests of
		Nothing -> error "No tests found!?"
		Just act -> ifM act
			( exitSuccess
			, do
				putStrLn "  (This could be due to a bug in git-annex, or an incompatability"
				putStrLn "   with utilities, such as git, installed on this system.)"
				exitFailure
			)
  where
	parseOpts pprefs pinfo args =
#if MIN_VERSION_optparse_applicative(0,10,0)
		case execParserPure pprefs pinfo args of
			(Options.Applicative.Failure failure) -> do
				let (msg, _exit) = renderFailure failure "git-annex test"
				error msg
			v -> handleParseResult v
#else
		handleParseResult $ execParserPure pprefs pinfo args
#endif

ingredients :: [Ingredient]
ingredients =
	[ listingTests
	, rerunningTests [consoleTestReporter]
	]

properties :: TestTree
properties = localOption (QuickCheckTests 1000) $ testGroup "QuickCheck"
	[ testProperty "prop_idempotent_deencode_git" Git.Filename.prop_idempotent_deencode
	, testProperty "prop_idempotent_deencode" Utility.Format.prop_idempotent_deencode
	, testProperty "prop_idempotent_fileKey" Locations.prop_idempotent_fileKey
	, testProperty "prop_idempotent_key_encode" Types.Key.prop_idempotent_key_encode
	, testProperty "prop_idempotent_key_decode" Types.Key.prop_idempotent_key_decode
	, testProperty "prop_idempotent_shellEscape" Utility.SafeCommand.prop_idempotent_shellEscape
	, testProperty "prop_idempotent_shellEscape_multiword" Utility.SafeCommand.prop_idempotent_shellEscape_multiword
	, testProperty "prop_idempotent_configEscape" Logs.Remote.prop_idempotent_configEscape
	, testProperty "prop_parse_show_Config" Logs.Remote.prop_parse_show_Config
	, testProperty "prop_upFrom_basics" Utility.Path.prop_upFrom_basics
	, testProperty "prop_relPathDirToFile_basics" Utility.Path.prop_relPathDirToFile_basics
	, testProperty "prop_relPathDirToFile_regressionTest" Utility.Path.prop_relPathDirToFile_regressionTest
	, testProperty "prop_cost_sane" Config.Cost.prop_cost_sane
	, testProperty "prop_matcher_sane" Utility.Matcher.prop_matcher_sane
	, testProperty "prop_HmacSha1WithCipher_sane" Crypto.prop_HmacSha1WithCipher_sane
	, testProperty "prop_TimeStamp_sane" Logs.MapLog.prop_TimeStamp_sane
	, testProperty "prop_addMapLog_sane" Logs.MapLog.prop_addMapLog_sane
	, testProperty "prop_verifiable_sane" Utility.Verifiable.prop_verifiable_sane
	, testProperty "prop_segment_regressionTest" Utility.Misc.prop_segment_regressionTest
	, testProperty "prop_read_write_transferinfo" Logs.Transfer.prop_read_write_transferinfo
	, testProperty "prop_read_show_inodecache" Utility.InodeCache.prop_read_show_inodecache
	, testProperty "prop_parse_show_log" Logs.Presence.prop_parse_show_log
	, testProperty "prop_read_show_TrustLevel" Types.TrustLevel.prop_read_show_TrustLevel
	, testProperty "prop_parse_show_TrustLog" Logs.Trust.prop_parse_show_TrustLog
	, testProperty "prop_hashes_stable" Utility.Hash.prop_hashes_stable
	, testProperty "prop_schedule_roundtrips" Utility.Scheduled.prop_schedule_roundtrips
	, testProperty "prop_past_sane" Utility.Scheduled.prop_past_sane
	, testProperty "prop_duration_roundtrips" Utility.HumanTime.prop_duration_roundtrips
	, testProperty "prop_metadata_sane" Types.MetaData.prop_metadata_sane
	, testProperty "prop_metadata_serialize" Types.MetaData.prop_metadata_serialize
	, testProperty "prop_branchView_legal" Logs.View.prop_branchView_legal
	, testProperty "prop_view_roundtrips" Annex.View.prop_view_roundtrips
	, testProperty "prop_viewedFile_rountrips" Annex.View.ViewedFile.prop_viewedFile_roundtrips
	, testProperty "prop_b64_roundtrips" Utility.Base64.prop_b64_roundtrips
	]

{- These tests set up the test environment, but also test some basic parts
 - of git-annex. They are always run before the unitTests. -}
initTests :: TestTree
initTests = testGroup "Init Tests"
	[ testCase "init" test_init
	, testCase "add" test_add
	]

unitTests :: String -> TestTree
unitTests note = testGroup ("Unit Tests " ++ note)
	[ testCase "add sha1dup" test_add_sha1dup
	, testCase "add extras" test_add_extras
	, testCase "reinject" test_reinject
	, testCase "unannex (no copy)" test_unannex_nocopy
	, testCase "unannex (with copy)" test_unannex_withcopy
	, testCase "drop (no remote)" test_drop_noremote
	, testCase "drop (with remote)" test_drop_withremote
	, testCase "drop (untrusted remote)" test_drop_untrustedremote
	, testCase "get" test_get
	, testCase "move" test_move
	, testCase "copy" test_copy
	, testCase "lock" test_lock
	, testCase "edit (no pre-commit)" test_edit
	, testCase "edit (pre-commit)" test_edit_precommit
	, testCase "partial commit" test_partial_commit
	, testCase "fix" test_fix
	, testCase "direct" test_direct
	, testCase "trust" test_trust
	, testCase "fsck (basics)" test_fsck_basic
	, testCase "fsck (bare)" test_fsck_bare
	, testCase "fsck (local untrusted)" test_fsck_localuntrusted
	, testCase "fsck (remote untrusted)" test_fsck_remoteuntrusted
	, testCase "migrate" test_migrate
	, testCase "migrate (via gitattributes)" test_migrate_via_gitattributes
	, testCase "unused" test_unused
	, testCase "describe" test_describe
	, testCase "find" test_find
	, testCase "merge" test_merge
	, testCase "info" test_info
	, testCase "version" test_version
	, testCase "sync" test_sync
	, testCase "union merge regression" test_union_merge_regression
	, testCase "conflict resolution" test_conflict_resolution
	, testCase "conflict resolution movein regression" test_conflict_resolution_movein_regression
	, testCase "conflict resolution (mixed directory and file)" test_mixed_conflict_resolution
	, testCase "conflict resolution symlink bit" test_conflict_resolution_symlink_bit
	, testCase "conflict resolution (uncommitted local file)" test_uncommitted_conflict_resolution
	, testCase "conflict resolution (removed file)" test_remove_conflict_resolution
	, testCase "conflict resolution (nonannexed file)" test_nonannexed_file_conflict_resolution
	, testCase "conflict resolution (nonannexed symlink)" test_nonannexed_symlink_conflict_resolution
	, testCase "map" test_map
	, testCase "uninit" test_uninit
	, testCase "uninit (in git-annex branch)" test_uninit_inbranch
	, testCase "upgrade" test_upgrade
	, testCase "whereis" test_whereis
	, testCase "hook remote" test_hook_remote
	, testCase "directory remote" test_directory_remote
	, testCase "rsync remote" test_rsync_remote
	, testCase "bup remote" test_bup_remote
	, testCase "crypto" test_crypto
	, testCase "preferred content" test_preferred_content
	, testCase "add subdirs" test_add_subdirs
	, testCase "addurl" test_addurl
	]

-- this test case create the main repo
test_init :: Assertion
test_init = innewrepo $ do
	git_annex "init" [reponame] @? "init failed"
	handleforcedirect
  where
	reponame = "test repo"

-- this test case runs in the main repo, to set up a basic
-- annexed file that later tests will use
test_add :: Assertion
test_add = inmainrepo $ do
	writeFile annexedfile $ content annexedfile
	git_annex "add" [annexedfile] @? "add failed"
	annexed_present annexedfile
	writeFile sha1annexedfile $ content sha1annexedfile
	git_annex "add" [sha1annexedfile, "--backend=SHA1"] @? "add with SHA1 failed"
	annexed_present sha1annexedfile
	checkbackend sha1annexedfile backendSHA1
	ifM (annexeval Config.isDirect)
		( do
			writeFile ingitfile $ content ingitfile
			not <$> boolSystem "git" [Param "add", File ingitfile] @? "git add failed to fail in direct mode"
			nukeFile ingitfile
			git_annex "sync" [] @? "sync failed"
		, do
			writeFile ingitfile $ content ingitfile
			boolSystem "git" [Param "add", File ingitfile] @? "git add failed"
			boolSystem "git" [Params "commit -q -m commit"] @? "git commit failed"
			git_annex "add" [ingitfile] @? "add ingitfile should be no-op"
			unannexed ingitfile
		)

test_add_sha1dup :: Assertion
test_add_sha1dup = intmpclonerepo $ do
	writeFile sha1annexedfiledup $ content sha1annexedfiledup
	git_annex "add" [sha1annexedfiledup, "--backend=SHA1"] @? "add of second file with same SHA1 failed"
	annexed_present sha1annexedfiledup
	annexed_present sha1annexedfile

test_add_extras :: Assertion
test_add_extras = intmpclonerepo $ do
	writeFile wormannexedfile $ content wormannexedfile
	git_annex "add" [wormannexedfile, "--backend=WORM"] @? "add with WORM failed"
	annexed_present wormannexedfile
	checkbackend wormannexedfile backendWORM

test_reinject :: Assertion
test_reinject = intmpclonerepoInDirect $ do
	git_annex "drop" ["--force", sha1annexedfile] @? "drop failed"
	writeFile tmp $ content sha1annexedfile
	r <- annexeval $ Types.Backend.getKey backendSHA1
		Types.KeySource.KeySource { Types.KeySource.keyFilename = tmp, Types.KeySource.contentLocation = tmp, Types.KeySource.inodeCache = Nothing }
	let key = Types.Key.key2file $ fromJust r
	git_annex "reinject" [tmp, sha1annexedfile] @? "reinject failed"
	git_annex "fromkey" [key, sha1annexedfiledup] @? "fromkey failed for dup"
	annexed_present sha1annexedfiledup
  where
	tmp = "tmpfile"

test_unannex_nocopy :: Assertion
test_unannex_nocopy = intmpclonerepo $ do
	annexed_notpresent annexedfile
	git_annex "unannex" [annexedfile] @? "unannex failed with no copy"
	annexed_notpresent annexedfile

test_unannex_withcopy :: Assertion
test_unannex_withcopy = intmpclonerepo $ do
	git_annex "get" [annexedfile] @? "get failed"
	annexed_present annexedfile
	git_annex "unannex" [annexedfile, sha1annexedfile] @? "unannex failed"
	unannexed annexedfile
	git_annex "unannex" [annexedfile] @? "unannex failed on non-annexed file"
	unannexed annexedfile
	unlessM (annexeval Config.isDirect) $ do
		git_annex "unannex" [ingitfile] @? "unannex ingitfile should be no-op"
		unannexed ingitfile

test_drop_noremote :: Assertion
test_drop_noremote = intmpclonerepo $ do
	git_annex "get" [annexedfile] @? "get failed"
	boolSystem "git" [Params "remote rm origin"]
		@? "git remote rm origin failed"
	not <$> git_annex "drop" [annexedfile] @? "drop wrongly succeeded with no known copy of file"
	annexed_present annexedfile
	git_annex "drop" ["--force", annexedfile] @? "drop --force failed"
	annexed_notpresent annexedfile
	git_annex "drop" [annexedfile] @? "drop of dropped file failed"
	unlessM (annexeval Config.isDirect) $ do
		git_annex "drop" [ingitfile] @? "drop ingitfile should be no-op"
		unannexed ingitfile

test_drop_withremote :: Assertion
test_drop_withremote = intmpclonerepo $ do
	git_annex "get" [annexedfile] @? "get failed"
	annexed_present annexedfile
	git_annex "numcopies" ["2"] @? "numcopies config failed"
	not <$> git_annex "drop" [annexedfile] @? "drop succeeded although numcopies is not satisfied"
	git_annex "numcopies" ["1"] @? "numcopies config failed"
	git_annex "drop" [annexedfile] @? "drop failed though origin has copy"
	annexed_notpresent annexedfile
	-- make sure that the correct symlink is staged for the file
	-- after drop
	git_annex_expectoutput "status" [] []
	inmainrepo $ annexed_present annexedfile

test_drop_untrustedremote :: Assertion
test_drop_untrustedremote = intmpclonerepo $ do
	git_annex "untrust" ["origin"] @? "untrust of origin failed"
	git_annex "get" [annexedfile] @? "get failed"
	annexed_present annexedfile
	not <$> git_annex "drop" [annexedfile] @? "drop wrongly suceeded with only an untrusted copy of the file"
	annexed_present annexedfile
	inmainrepo $ annexed_present annexedfile

test_get :: Assertion
test_get = intmpclonerepo $ do
	inmainrepo $ annexed_present annexedfile
	annexed_notpresent annexedfile
	git_annex "get" [annexedfile] @? "get of file failed"
	inmainrepo $ annexed_present annexedfile
	annexed_present annexedfile
	git_annex "get" [annexedfile] @? "get of file already here failed"
	inmainrepo $ annexed_present annexedfile
	annexed_present annexedfile
	unlessM (annexeval Config.isDirect) $ do
		inmainrepo $ unannexed ingitfile
		unannexed ingitfile
		git_annex "get" [ingitfile] @? "get ingitfile should be no-op"
		inmainrepo $ unannexed ingitfile
		unannexed ingitfile

test_move :: Assertion
test_move = intmpclonerepo $ do
	annexed_notpresent annexedfile
	inmainrepo $ annexed_present annexedfile
	git_annex "move" ["--from", "origin", annexedfile] @? "move --from of file failed"
	annexed_present annexedfile
	inmainrepo $ annexed_notpresent annexedfile
	git_annex "move" ["--from", "origin", annexedfile] @? "move --from of file already here failed"
	annexed_present annexedfile
	inmainrepo $ annexed_notpresent annexedfile
	git_annex "move" ["--to", "origin", annexedfile] @? "move --to of file failed"
	inmainrepo $ annexed_present annexedfile
	annexed_notpresent annexedfile
	git_annex "move" ["--to", "origin", annexedfile] @? "move --to of file already there failed"
	inmainrepo $ annexed_present annexedfile
	annexed_notpresent annexedfile
	unlessM (annexeval Config.isDirect) $ do
		unannexed ingitfile
		inmainrepo $ unannexed ingitfile
		git_annex "move" ["--to", "origin", ingitfile] @? "move of ingitfile should be no-op"
		unannexed ingitfile
		inmainrepo $ unannexed ingitfile
		git_annex "move" ["--from", "origin", ingitfile] @? "move of ingitfile should be no-op"
		unannexed ingitfile
		inmainrepo $ unannexed ingitfile

test_copy :: Assertion
test_copy = intmpclonerepo $ do
	annexed_notpresent annexedfile
	inmainrepo $ annexed_present annexedfile
	git_annex "copy" ["--from", "origin", annexedfile] @? "copy --from of file failed"
	annexed_present annexedfile
	inmainrepo $ annexed_present annexedfile
	git_annex "copy" ["--from", "origin", annexedfile] @? "copy --from of file already here failed"
	annexed_present annexedfile
	inmainrepo $ annexed_present annexedfile
	git_annex "copy" ["--to", "origin", annexedfile] @? "copy --to of file already there failed"
	annexed_present annexedfile
	inmainrepo $ annexed_present annexedfile
	git_annex "move" ["--to", "origin", annexedfile] @? "move --to of file already there failed"
	annexed_notpresent annexedfile
	inmainrepo $ annexed_present annexedfile
	unlessM (annexeval Config.isDirect) $ do
		unannexed ingitfile
		inmainrepo $ unannexed ingitfile
		git_annex "copy" ["--to", "origin", ingitfile] @? "copy of ingitfile should be no-op"
		unannexed ingitfile
		inmainrepo $ unannexed ingitfile
		git_annex "copy" ["--from", "origin", ingitfile] @? "copy of ingitfile should be no-op"
		checkregularfile ingitfile
		checkcontent ingitfile

test_preferred_content :: Assertion
test_preferred_content = intmpclonerepo $ do
	annexed_notpresent annexedfile
	-- get --auto only looks at numcopies when preferred content is not
	-- set, and with 1 copy existing, does not get the file.
	git_annex "get" ["--auto", annexedfile] @? "get --auto of file failed with default preferred content"
	annexed_notpresent annexedfile

	git_annex "wanted" [".", "standard"] @? "set expression to standard failed"
	git_annex "group" [".", "client"] @? "set group to standard failed"
	git_annex "get" ["--auto", annexedfile] @? "get --auto of file failed for client"
	annexed_present annexedfile
	git_annex "ungroup" [".", "client"] @? "ungroup failed"

	git_annex "wanted" [".", "standard"] @? "set expression to standard failed"
	git_annex "group" [".", "manual"] @? "set group to manual failed"
	-- drop --auto with manual leaves the file where it is
	git_annex "drop" ["--auto", annexedfile] @? "drop --auto of file failed with manual preferred content"
	annexed_present annexedfile
	git_annex "drop" [annexedfile] @? "drop of file failed"
	annexed_notpresent annexedfile
	-- get --auto with manual does not get the file
	git_annex "get" ["--auto", annexedfile] @? "get --auto of file failed with manual preferred content"
	annexed_notpresent annexedfile
	git_annex "ungroup" [".", "client"] @? "ungroup failed"
	
	git_annex "wanted" [".", "exclude=*"] @? "set expression to exclude=* failed"
	git_annex "get" [annexedfile] @? "get of file failed"
	annexed_present annexedfile
	git_annex "drop" ["--auto", annexedfile] @? "drop --auto of file failed with exclude=*"
	annexed_notpresent annexedfile
	git_annex "get" ["--auto", annexedfile] @? "get --auto of file failed with exclude=*"
	annexed_notpresent annexedfile

test_lock :: Assertion
test_lock = intmpclonerepoInDirect $ do
	-- regression test: unlock of not present file should skip it
	annexed_notpresent annexedfile
	not <$> git_annex "unlock" [annexedfile] @? "unlock failed to fail with not present file"
	annexed_notpresent annexedfile

	-- regression test: unlock of newly added, not committed file
	-- should fail
	writeFile "newfile" "foo"
	git_annex "add" ["newfile"] @? "add new file failed"
	not <$> git_annex "unlock" ["newfile"] @? "unlock failed to fail on newly added, never committed file"

	git_annex "get" [annexedfile] @? "get of file failed"
	annexed_present annexedfile
	git_annex "unlock" [annexedfile] @? "unlock failed"		
	unannexed annexedfile
	-- write different content, to verify that lock
	-- throws it away
	changecontent annexedfile
	writeFile annexedfile $ content annexedfile ++ "foo"
	not <$> git_annex "lock" [annexedfile] @? "lock failed to fail without --force"
	git_annex "lock" ["--force", annexedfile] @? "lock --force failed"
	annexed_present annexedfile
	git_annex "unlock" [annexedfile] @? "unlock failed"		
	unannexed annexedfile
	changecontent annexedfile
	git_annex "add" [annexedfile] @? "add of modified file failed"
	runchecks [checklink, checkunwritable] annexedfile
	c <- readFile annexedfile
	assertEqual "content of modified file" c (changedcontent annexedfile)
	r' <- git_annex "drop" [annexedfile]
	not r' @? "drop wrongly succeeded with no known copy of modified file"

test_edit :: Assertion
test_edit = test_edit' False

test_edit_precommit :: Assertion
test_edit_precommit = test_edit' True

test_edit' :: Bool -> Assertion
test_edit' precommit = intmpclonerepoInDirect $ do
	git_annex "get" [annexedfile] @? "get of file failed"
	annexed_present annexedfile
	git_annex "edit" [annexedfile] @? "edit failed"
	unannexed annexedfile
	changecontent annexedfile
	boolSystem "git" [Param "add", File annexedfile]
		@? "git add of edited file failed"
	if precommit
		then git_annex "pre-commit" []
			@? "pre-commit failed"
		else boolSystem "git" [Params "commit -q -m contentchanged"]
			@? "git commit of edited file failed"
	runchecks [checklink, checkunwritable] annexedfile
	c <- readFile annexedfile
	assertEqual "content of modified file" c (changedcontent annexedfile)
	not <$> git_annex "drop" [annexedfile] @? "drop wrongly succeeded with no known copy of modified file"

test_partial_commit :: Assertion
test_partial_commit = intmpclonerepoInDirect $ do
	git_annex "get" [annexedfile] @? "get of file failed"
	annexed_present annexedfile
	git_annex "unlock" [annexedfile] @? "unlock failed"
	not <$> boolSystem "git" [Params "commit -q -m test", File annexedfile]
		@? "partial commit of unlocked file not blocked by pre-commit hook"

test_fix :: Assertion
test_fix = intmpclonerepoInDirect $ do
	annexed_notpresent annexedfile
	git_annex "fix" [annexedfile] @? "fix of not present failed"
	annexed_notpresent annexedfile
	git_annex "get" [annexedfile] @? "get of file failed"
	annexed_present annexedfile
	git_annex "fix" [annexedfile] @? "fix of present file failed"
	annexed_present annexedfile
	createDirectory subdir
	boolSystem "git" [Param "mv", File annexedfile, File subdir]
		@? "git mv failed"
	git_annex "fix" [newfile] @? "fix of moved file failed"
	runchecks [checklink, checkunwritable] newfile
	c <- readFile newfile
	assertEqual "content of moved file" c (content annexedfile)
  where
	subdir = "s"
	newfile = subdir ++ "/" ++ annexedfile

test_direct :: Assertion
test_direct = intmpclonerepoInDirect $ do
	git_annex "get" [annexedfile] @? "get of file failed"
	annexed_present annexedfile
	git_annex "direct" [] @? "switch to direct mode failed"
	annexed_present annexedfile
	git_annex "indirect" [] @? "switch to indirect mode failed"

test_trust :: Assertion
test_trust = intmpclonerepo $ do
	git_annex "trust" [repo] @? "trust failed"
	trustcheck Logs.Trust.Trusted "trusted 1"
	git_annex "trust" [repo] @? "trust of trusted failed"
	trustcheck Logs.Trust.Trusted "trusted 2"
	git_annex "untrust" [repo] @? "untrust failed"
	trustcheck Logs.Trust.UnTrusted "untrusted 1"
	git_annex "untrust" [repo] @? "untrust of untrusted failed"
	trustcheck Logs.Trust.UnTrusted "untrusted 2"
	git_annex "dead" [repo] @? "dead failed"
	trustcheck Logs.Trust.DeadTrusted "deadtrusted 1"
	git_annex "dead" [repo] @? "dead of dead failed"
	trustcheck Logs.Trust.DeadTrusted "deadtrusted 2"
	git_annex "semitrust" [repo] @? "semitrust failed"
	trustcheck Logs.Trust.SemiTrusted "semitrusted 1"
	git_annex "semitrust" [repo] @? "semitrust of semitrusted failed"
	trustcheck Logs.Trust.SemiTrusted "semitrusted 2"
  where
	repo = "origin"
	trustcheck expected msg = do
		present <- annexeval $ do
			l <- Logs.Trust.trustGet expected
			u <- Remote.nameToUUID repo
			return $ u `elem` l
		assertBool msg present

test_fsck_basic :: Assertion
test_fsck_basic = intmpclonerepo $ do
	git_annex "fsck" [] @? "fsck failed"
	git_annex "numcopies" ["2"] @? "numcopies config failed"
	fsck_should_fail "numcopies unsatisfied"
	git_annex "numcopies" ["1"] @? "numcopies config failed"
	corrupt annexedfile
	corrupt sha1annexedfile
  where
	corrupt f = do
		git_annex "get" [f] @? "get of file failed"
		Utility.FileMode.allowWrite f
		writeFile f (changedcontent f)
		ifM (annexeval Config.isDirect)
			( git_annex "fsck" [] @? "fsck failed in direct mode with changed file content"
			, not <$> git_annex "fsck" [] @? "fsck failed to fail with corrupted file content"
			)
		git_annex "fsck" [] @? "fsck unexpectedly failed again; previous one did not fix problem with " ++ f

test_fsck_bare :: Assertion
test_fsck_bare = intmpbareclonerepo $
	git_annex "fsck" [] @? "fsck failed"

test_fsck_localuntrusted :: Assertion
test_fsck_localuntrusted = intmpclonerepo $ do
	git_annex "get" [annexedfile] @? "get failed"
	git_annex "untrust" ["origin"] @? "untrust of origin repo failed"
	git_annex "untrust" ["."] @? "untrust of current repo failed"
	fsck_should_fail "content only available in untrusted (current) repository"
	git_annex "trust" ["."] @? "trust of current repo failed"
	git_annex "fsck" [annexedfile] @? "fsck failed on file present in trusted repo"

test_fsck_remoteuntrusted :: Assertion
test_fsck_remoteuntrusted = intmpclonerepo $ do
	git_annex "numcopies" ["2"] @? "numcopies config failed"
	git_annex "get" [annexedfile] @? "get failed"
	git_annex "get" [sha1annexedfile] @? "get failed"
	git_annex "fsck" [] @? "fsck failed with numcopies=2 and 2 copies"
	git_annex "untrust" ["origin"] @? "untrust of origin failed"
	fsck_should_fail "content not replicated to enough non-untrusted repositories"

fsck_should_fail :: String -> Assertion
fsck_should_fail m = not <$> git_annex "fsck" []
	@? "fsck failed to fail with " ++ m

test_migrate :: Assertion
test_migrate = test_migrate' False

test_migrate_via_gitattributes :: Assertion
test_migrate_via_gitattributes = test_migrate' True

test_migrate' :: Bool -> Assertion
test_migrate' usegitattributes = intmpclonerepoInDirect $ do
	annexed_notpresent annexedfile
	annexed_notpresent sha1annexedfile
	git_annex "migrate" [annexedfile] @? "migrate of not present failed"
	git_annex "migrate" [sha1annexedfile] @? "migrate of not present failed"
	git_annex "get" [annexedfile] @? "get of file failed"
	git_annex "get" [sha1annexedfile] @? "get of file failed"
	annexed_present annexedfile
	annexed_present sha1annexedfile
	if usegitattributes
		then do
			writeFile ".gitattributes" "* annex.backend=SHA1"
			git_annex "migrate" [sha1annexedfile]
				@? "migrate sha1annexedfile failed"
			git_annex "migrate" [annexedfile]
				@? "migrate annexedfile failed"
		else do
			git_annex "migrate" [sha1annexedfile, "--backend", "SHA1"]
				@? "migrate sha1annexedfile failed"
			git_annex "migrate" [annexedfile, "--backend", "SHA1"]
				@? "migrate annexedfile failed"
	annexed_present annexedfile
	annexed_present sha1annexedfile
	checkbackend annexedfile backendSHA1
	checkbackend sha1annexedfile backendSHA1

	-- check that reversing a migration works
	writeFile ".gitattributes" "* annex.backend=SHA256"
	git_annex "migrate" [sha1annexedfile]
		@? "migrate sha1annexedfile failed"
	git_annex "migrate" [annexedfile]
		@? "migrate annexedfile failed"
	annexed_present annexedfile
	annexed_present sha1annexedfile
	checkbackend annexedfile backendSHA256
	checkbackend sha1annexedfile backendSHA256

test_unused :: Assertion
-- This test is broken in direct mode
test_unused = intmpclonerepoInDirect $ do
	-- keys have to be looked up before files are removed
	annexedfilekey <- annexeval $ findkey annexedfile
	sha1annexedfilekey <- annexeval $ findkey sha1annexedfile
	git_annex "get" [annexedfile] @? "get of file failed"
	git_annex "get" [sha1annexedfile] @? "get of file failed"
	checkunused [] "after get"
	boolSystem "git" [Params "rm -fq", File annexedfile] @? "git rm failed"
	checkunused [] "after rm"
	boolSystem "git" [Params "commit -q -m foo"] @? "git commit failed"
	checkunused [] "after commit"
	-- unused checks origin/master; once it's gone it is really unused
	boolSystem "git" [Params "remote rm origin"] @? "git remote rm origin failed"
	checkunused [annexedfilekey] "after origin branches are gone"
	boolSystem "git" [Params "rm -fq", File sha1annexedfile] @? "git rm failed"
	boolSystem "git" [Params "commit -q -m foo"] @? "git commit failed"
	checkunused [annexedfilekey, sha1annexedfilekey] "after rm sha1annexedfile"

	-- good opportunity to test dropkey also
	git_annex "dropkey" ["--force", Types.Key.key2file annexedfilekey]
		@? "dropkey failed"
	checkunused [sha1annexedfilekey] ("after dropkey --force " ++ Types.Key.key2file annexedfilekey)

	not <$> git_annex "dropunused" ["1"] @? "dropunused failed to fail without --force"
	git_annex "dropunused" ["--force", "1"] @? "dropunused failed"
	checkunused [] "after dropunused"
	not <$> git_annex "dropunused" ["--force", "10", "501"] @? "dropunused failed to fail on bogus numbers"

	-- unused used to miss symlinks that were not staged and pointed 
	-- at annexed content, and think that content was unused
	writeFile "unusedfile" "unusedcontent"
	git_annex "add" ["unusedfile"] @? "add of unusedfile failed"
	unusedfilekey <- annexeval $ findkey "unusedfile"
	renameFile "unusedfile" "unusedunstagedfile"
	boolSystem "git" [Params "rm -qf", File "unusedfile"] @? "git rm failed"
	checkunused [] "with unstaged link"
	removeFile "unusedunstagedfile"
	checkunused [unusedfilekey] "with unstaged link deleted"

	-- unused used to miss symlinks that were deleted or modified
	-- manually, but commited as such.
	writeFile "unusedfile" "unusedcontent"
	git_annex "add" ["unusedfile"] @? "add of unusedfile failed"
	boolSystem "git" [Param "add", File "unusedfile"] @? "git add failed"
	unusedfilekey' <- annexeval $ findkey "unusedfile"
	checkunused [] "with staged deleted link"
	boolSystem "git" [Params "rm -qf", File "unusedfile"] @? "git rm failed"
	checkunused [unusedfilekey'] "with staged link deleted"

	-- unused used to miss symlinks that were deleted or modified
	-- manually, but not staged as such.
	writeFile "unusedfile" "unusedcontent"
	git_annex "add" ["unusedfile"] @? "add of unusedfile failed"
	boolSystem "git" [Param "add", File "unusedfile"] @? "git add failed"
	unusedfilekey'' <- annexeval $ findkey "unusedfile"
	checkunused [] "with unstaged deleted link"
	removeFile "unusedfile"
	checkunused [unusedfilekey''] "with unstaged link deleted"

  where
	checkunused expectedkeys desc = do
		git_annex "unused" [] @? "unused failed"
		unusedmap <- annexeval $ Logs.Unused.readUnusedMap ""
		let unusedkeys = M.elems unusedmap
		assertEqual ("unused keys differ " ++ desc)
			(sort expectedkeys) (sort unusedkeys)
	findkey f = do
		r <- Backend.lookupFile f
		return $ fromJust r

test_describe :: Assertion
test_describe = intmpclonerepo $ do
	git_annex "describe" [".", "this repo"] @? "describe 1 failed"
	git_annex "describe" ["origin", "origin repo"] @? "describe 2 failed"

test_find :: Assertion
test_find = intmpclonerepo $ do
	annexed_notpresent annexedfile
	git_annex_expectoutput "find" [] []
	git_annex "get" [annexedfile] @? "get failed"
	annexed_present annexedfile
	annexed_notpresent sha1annexedfile
	git_annex_expectoutput "find" [] [annexedfile]
	git_annex_expectoutput "find" ["--exclude", annexedfile, "--and", "--exclude", sha1annexedfile] []
	git_annex_expectoutput "find" ["--include", annexedfile] [annexedfile]
	git_annex_expectoutput "find" ["--not", "--in", "origin"] []
	git_annex_expectoutput "find" ["--copies", "1", "--and", "--not", "--copies", "2"] [sha1annexedfile]
	git_annex_expectoutput "find" ["--inbackend", "SHA1"] [sha1annexedfile]
	git_annex_expectoutput "find" ["--inbackend", "WORM"] []

	{- --include=* should match files in subdirectories too,
	 - and --exclude=* should exclude them. -}
	createDirectory "dir"
	writeFile "dir/subfile" "subfile"
	git_annex "add" ["dir"] @? "add of subdir failed"
	git_annex_expectoutput "find" ["--include", "*", "--exclude", annexedfile, "--exclude", sha1annexedfile] ["dir/subfile"]
	git_annex_expectoutput "find" ["--exclude", "*"] []

test_merge :: Assertion
test_merge = intmpclonerepo $
	git_annex "merge" [] @? "merge failed"

test_info :: Assertion
test_info = intmpclonerepo $ do
	json <- git_annex_output "info" ["--json"]
	case Text.JSON.decodeStrict json :: Text.JSON.Result (Text.JSON.JSObject Text.JSON.JSValue) of
		Text.JSON.Ok _ -> return ()
		Text.JSON.Error e -> assertFailure e

test_version :: Assertion
test_version = intmpclonerepo $
	git_annex "version" [] @? "version failed"

test_sync :: Assertion
test_sync = intmpclonerepo $ do
	git_annex "sync" [] @? "sync failed"
	{- Regression test for bug fixed in 
	 - 7b0970b340d7faeb745c666146c7f701ec71808f, where in direct mode
	 - sync committed the symlink standin file to the annex. -}
	git_annex_expectoutput "find" ["--in", "."] []

{- Regression test for union merge bug fixed in
 - 0214e0fb175a608a49b812d81b4632c081f63027 -}
test_union_merge_regression :: Assertion
test_union_merge_regression =
	{- We need 3 repos to see this bug. -}
	withtmpclonerepo False $ \r1 ->
		withtmpclonerepo False $ \r2 ->
			withtmpclonerepo False $ \r3 -> do
				forM_ [r1, r2, r3] $ \r -> indir r $ do
					when (r /= r1) $
						boolSystem "git" [Params "remote add r1", File ("../../" ++ r1)] @? "remote add"
					when (r /= r2) $
						boolSystem "git" [Params "remote add r2", File ("../../" ++ r2)] @? "remote add"
					when (r /= r3) $
						boolSystem "git" [Params "remote add r3", File ("../../" ++ r3)] @? "remote add"
					git_annex "get" [annexedfile] @? "get failed"
					boolSystem "git" [Params "remote rm origin"] @? "remote rm"
				forM_ [r3, r2, r1] $ \r -> indir r $
					git_annex "sync" [] @? "sync failed"
				forM_ [r3, r2] $ \r -> indir r $
					git_annex "drop" ["--force", annexedfile] @? "drop failed"
				indir r1 $ do
					git_annex "sync" [] @? "sync failed in r1"
					git_annex_expectoutput "find" ["--in", "r3"] []
					{- This was the bug. The sync
					 - mangled location log data and it
					 - thought the file was still in r2 -}
					git_annex_expectoutput "find" ["--in", "r2"] []

{- Regression test for the automatic conflict resolution bug fixed
 - in f4ba19f2b8a76a1676da7bb5850baa40d9c388e2. -}
test_conflict_resolution_movein_regression :: Assertion
test_conflict_resolution_movein_regression = withtmpclonerepo False $ \r1 -> 
	withtmpclonerepo False $ \r2 -> do
		let rname r = if r == r1 then "r1" else "r2"
		forM_ [r1, r2] $ \r -> indir r $ do
			{- Get all files, see check below. -}
			git_annex "get" [] @? "get failed"
			disconnectOrigin
		pair r1 r2
		forM_ [r1, r2] $ \r -> indir r $ do
			{- Set up a conflict. -}
			let newcontent = content annexedfile ++ rname r
			ifM (annexeval Config.isDirect)
				( writeFile annexedfile newcontent
				, do
					git_annex "unlock" [annexedfile] @? "unlock failed"		
					writeFile annexedfile newcontent
				)
		{- Sync twice in r1 so it gets the conflict resolution
		 - update from r2 -}
		forM_ [r1, r2, r1] $ \r -> indir r $
			git_annex "sync" ["--force"] @? "sync failed in " ++ rname r
		{- After the sync, it should be possible to get all
		 - files. This includes both sides of the conflict,
		 - although the filenames are not easily predictable.
		 -
		 - The bug caused, in direct mode, one repo to
		 - be missing the content of the file that had
		 - been put in it. -}
		forM_ [r1, r2] $ \r -> indir r $ do
			git_annex "get" [] @? "unable to get all files after merge conflict resolution in " ++ rname r

{- Simple case of conflict resolution; 2 different versions of annexed
 - file. -}
test_conflict_resolution :: Assertion
test_conflict_resolution = 
	withtmpclonerepo False $ \r1 ->
		withtmpclonerepo False $ \r2 -> do
			indir r1 $ do
				disconnectOrigin
				writeFile conflictor "conflictor1"
				git_annex "add" [conflictor] @? "add conflicter failed"
				git_annex "sync" [] @? "sync failed in r1"
			indir r2 $ do
				disconnectOrigin
				writeFile conflictor "conflictor2"
				git_annex "add" [conflictor] @? "add conflicter failed"
				git_annex "sync" [] @? "sync failed in r2"
			pair r1 r2
			forM_ [r1,r2,r1] $ \r -> indir r $
				git_annex "sync" [] @? "sync failed"
			checkmerge "r1" r1
			checkmerge "r2" r2
  where
	conflictor = "conflictor"
	variantprefix = conflictor ++ ".variant"
	checkmerge what d = do
		l <- getDirectoryContents d
		let v = filter (variantprefix `isPrefixOf`) l
		length v == 2
			@? (what ++ " not exactly 2 variant files in: " ++ show l)
		conflictor `notElem` l @? ("conflictor still present after conflict resolution")
		indir d $ do
			git_annex "get" v @? "get failed"
			git_annex_expectoutput "find" v v


{- Check merge conflict resolution when one side is an annexed
 - file, and the other is a directory. -}
test_mixed_conflict_resolution :: Assertion
test_mixed_conflict_resolution = do
	check True
	check False
  where
	check inr1 = withtmpclonerepo False $ \r1 ->
		withtmpclonerepo False $ \r2 -> do
			indir r1 $ do
				disconnectOrigin
				writeFile conflictor "conflictor"
				git_annex "add" [conflictor] @? "add conflicter failed"
				git_annex "sync" [] @? "sync failed in r1"
			indir r2 $ do
				disconnectOrigin
				createDirectory conflictor
				writeFile subfile "subfile"
				git_annex "add" [conflictor] @? "add conflicter failed"
				git_annex "sync" [] @? "sync failed in r2"
			pair r1 r2
			let l = if inr1 then [r1, r2] else [r2, r1]
			forM_ l $ \r -> indir r $
				git_annex "sync" [] @? "sync failed in mixed conflict"
			checkmerge "r1" r1
			checkmerge "r2" r2
	conflictor = "conflictor"
	subfile = conflictor </> "subfile"
	variantprefix = conflictor ++ ".variant"
	checkmerge what d = do
		doesDirectoryExist (d </> conflictor) @? (d ++ " conflictor directory missing")
		l <- getDirectoryContents d
		let v = filter (variantprefix `isPrefixOf`) l
		not (null v)
			@? (what ++ " conflictor variant file missing in: " ++ show l )
		length v == 1
			@? (what ++ " too many variant files in: " ++ show v)
		indir d $ do
			git_annex "get" (conflictor:v) @? ("get failed in " ++ what)
			git_annex_expectoutput "find" [conflictor] [Git.FilePath.toInternalGitPath subfile]
			git_annex_expectoutput "find" v v

{- Check merge conflict resolution when both repos start with an annexed
 - file; one modifies it, and the other deletes it. -}
test_remove_conflict_resolution :: Assertion
test_remove_conflict_resolution = do
	check True
	check False
  where
	check inr1 = withtmpclonerepo False $ \r1 ->
		withtmpclonerepo False $ \r2 -> do
			indir r1 $ do
				disconnectOrigin
				writeFile conflictor "conflictor"
				git_annex "add" [conflictor] @? "add conflicter failed"
				git_annex "sync" [] @? "sync failed in r1"
			indir r2 $
				disconnectOrigin
			pair r1 r2
			indir r2 $ do
				git_annex "sync" [] @? "sync failed in r2"
				git_annex "get" [conflictor]
					@? "get conflictor failed"
				unlessM (annexeval Config.isDirect) $ do
					git_annex "unlock" [conflictor]
						@? "unlock conflictor failed"
				writeFile conflictor "newconflictor"
			indir r1 $
				nukeFile conflictor
			let l = if inr1 then [r1, r2, r1] else [r2, r1, r2]
			forM_ l $ \r -> indir r $
				git_annex "sync" [] @? "sync failed"
			checkmerge "r1" r1
			checkmerge "r2" r2
	conflictor = "conflictor"
	variantprefix = conflictor ++ ".variant"
	checkmerge what d = do
		l <- getDirectoryContents d
		let v = filter (variantprefix `isPrefixOf`) l
		not (null v)
			@? (what ++ " conflictor variant file missing in: " ++ show l )
		length v == 1
			@? (what ++ " too many variant files in: " ++ show v)

{- Check merge confalict resolution when a file is annexed in one repo,
 - and checked directly into git in the other repo.
 -
 - This test requires indirect mode to set it up, but tests both direct and
 - indirect mode.
 -}
test_nonannexed_file_conflict_resolution :: Assertion
test_nonannexed_file_conflict_resolution = do
	check True False
	check False False
	check True True
	check False True
  where
	check inr1 switchdirect = withtmpclonerepo False $ \r1 ->
		withtmpclonerepo False $ \r2 ->
			whenM (isInDirect r1 <&&> isInDirect r2) $ do
				indir r1 $ do
					disconnectOrigin
					writeFile conflictor "conflictor"
					git_annex "add" [conflictor] @? "add conflicter failed"
					git_annex "sync" [] @? "sync failed in r1"
				indir r2 $ do
					disconnectOrigin
					writeFile conflictor nonannexed_content
					boolSystem "git" [Params "add", File conflictor] @? "git add conflictor failed"
					git_annex "sync" [] @? "sync failed in r2"
				pair r1 r2
				let l = if inr1 then [r1, r2] else [r2, r1]
				forM_ l $ \r -> indir r $ do
					when switchdirect $
						git_annex "direct" [] @? "failed switching to direct mode"
					git_annex "sync" [] @? "sync failed"
				checkmerge ("r1" ++ show switchdirect) r1
				checkmerge ("r2" ++ show switchdirect) r2
	conflictor = "conflictor"
	nonannexed_content = "nonannexed"
	variantprefix = conflictor ++ ".variant"
	checkmerge what d = do
		l <- getDirectoryContents d
		let v = filter (variantprefix `isPrefixOf`) l
		not (null v)
			@? (what ++ " conflictor variant file missing in: " ++ show l )
		length v == 1
			@? (what ++ " too many variant files in: " ++ show v)
		conflictor `elem` l @? (what ++ " conflictor file missing in: " ++ show l)
		s <- catchMaybeIO (readFile (d </> conflictor))
		s == Just nonannexed_content
			@? (what ++ " wrong content for nonannexed file: " ++ show s)


{- Check merge confalict resolution when a file is annexed in one repo,
 - and is a non-git-annex symlink in the other repo.
 -
 - Test can only run when coreSymlinks is supported, because git needs to
 - be able to check out the non-git-annex symlink.
 -}
test_nonannexed_symlink_conflict_resolution :: Assertion
test_nonannexed_symlink_conflict_resolution = do
	check True False
	check False False
	check True True
	check False True
  where
	check inr1 switchdirect = withtmpclonerepo False $ \r1 ->
		withtmpclonerepo False $ \r2 ->
			whenM (checkRepo (Types.coreSymlinks <$> Annex.getGitConfig) r1
			       <&&> isInDirect r1 <&&> isInDirect r2) $ do
				indir r1 $ do
					disconnectOrigin
					writeFile conflictor "conflictor"
					git_annex "add" [conflictor] @? "add conflicter failed"
					git_annex "sync" [] @? "sync failed in r1"
				indir r2 $ do
					disconnectOrigin
					createSymbolicLink symlinktarget "conflictor"
					boolSystem "git" [Params "add", File conflictor] @? "git add conflictor failed"
					git_annex "sync" [] @? "sync failed in r2"
				pair r1 r2
				let l = if inr1 then [r1, r2] else [r2, r1]
				forM_ l $ \r -> indir r $ do
					when switchdirect $
						git_annex "direct" [] @? "failed switching to direct mode"
					git_annex "sync" [] @? "sync failed"
				checkmerge ("r1" ++ show switchdirect) r1
				checkmerge ("r2" ++ show switchdirect) r2
	conflictor = "conflictor"
	symlinktarget = "dummy-target"
	variantprefix = conflictor ++ ".variant"
	checkmerge what d = do
		l <- getDirectoryContents d
		let v = filter (variantprefix `isPrefixOf`) l
		not (null v)
			@? (what ++ " conflictor variant file missing in: " ++ show l )
		length v == 1
			@? (what ++ " too many variant files in: " ++ show v)
		conflictor `elem` l @? (what ++ " conflictor file missing in: " ++ show l)
		s <- catchMaybeIO (readSymbolicLink (d </> conflictor))
		s == Just symlinktarget
			@? (what ++ " wrong target for nonannexed symlink: " ++ show s)

{- Check merge conflict resolution when there is a local file,
 - that is not staged or committed, that conflicts with what's being added
 - from the remmote.
 -
 - Case 1: Remote adds file named conflictor; local has a file named
 - conflictor.
 -
 - Case 2: Remote adds conflictor/file; local has a file named conflictor.
 -}
test_uncommitted_conflict_resolution :: Assertion
test_uncommitted_conflict_resolution = do
	check conflictor
	check (conflictor </> "file")
  where
	check remoteconflictor = withtmpclonerepo False $ \r1 ->
		withtmpclonerepo False $ \r2 -> do
			indir r1 $ do
				disconnectOrigin
				createDirectoryIfMissing True (parentDir remoteconflictor)
				writeFile remoteconflictor annexedcontent
				git_annex "add" [conflictor] @? "add remoteconflicter failed"
				git_annex "sync" [] @? "sync failed in r1"
			indir r2 $ do
				disconnectOrigin
				writeFile conflictor localcontent
			pair r1 r2
			indir r2 $ ifM (annexeval Config.isDirect)
				( do
					git_annex "sync" [] @? "sync failed"
					let local = conflictor ++ localprefix
					doesFileExist local @? (local ++ " missing after merge")
					s <- readFile local
					s == localcontent @? (local ++ " has wrong content: " ++ s)
					git_annex "get" [conflictor] @? "get failed"
					doesFileExist remoteconflictor @? (remoteconflictor ++ " missing after merge")
					s' <- readFile remoteconflictor
					s' == annexedcontent @? (remoteconflictor ++ " has wrong content: " ++ s)
				-- this case is intentionally not handled
				-- in indirect mode, since the user
				-- can recover on their own easily
				, not <$> git_annex "sync" [] @? "sync failed to fail"
				)
	conflictor = "conflictor"
	localprefix = ".variant-local"
	localcontent = "local"
	annexedcontent = "annexed"

{- On Windows/FAT, repeated conflict resolution sometimes 
 - lost track of whether a file was a symlink. 
 -}
test_conflict_resolution_symlink_bit :: Assertion
test_conflict_resolution_symlink_bit =
	withtmpclonerepo False $ \r1 ->
		withtmpclonerepo False $ \r2 ->
			withtmpclonerepo False $ \r3 -> do
				indir r1 $ do
					writeFile conflictor "conflictor"
					git_annex "add" [conflictor] @? "add conflicter failed"
					git_annex "sync" [] @? "sync failed in r1"
					check_is_link conflictor "r1"
				indir r2 $ do
					createDirectory conflictor
					writeFile (conflictor </> "subfile") "subfile"
					git_annex "add" [conflictor] @? "add conflicter failed"
					git_annex "sync" [] @? "sync failed in r2"
					check_is_link (conflictor </> "subfile") "r2"
				indir r3 $ do
					writeFile conflictor "conflictor"
					git_annex "add" [conflictor] @? "add conflicter failed"
					git_annex "sync" [] @? "sync failed in r1"
					check_is_link (conflictor </> "subfile") "r3"
  where
	conflictor = "conflictor"
	check_is_link f what = do
		git_annex_expectoutput "find" ["--include=*", f] [Git.FilePath.toInternalGitPath f]
		l <- annexeval $ Annex.inRepo $ Git.LsTree.lsTreeFiles Git.Ref.headRef [f]
		all (\i -> Git.Types.toBlobType (Git.LsTree.mode i) == Just Git.Types.SymlinkBlob) l
			@? (what ++ " " ++ f ++ " lost symlink bit after merge: " ++ show l)

{- Set up repos as remotes of each other. -}
pair :: FilePath -> FilePath -> Assertion
pair r1 r2 = forM_ [r1, r2] $ \r -> indir r $ do
	when (r /= r1) $
		boolSystem "git" [Params "remote add r1", File ("../../" ++ r1)] @? "remote add"
	when (r /= r2) $
		boolSystem "git" [Params "remote add r2", File ("../../" ++ r2)] @? "remote add"

test_map :: Assertion
test_map = intmpclonerepo $ do
	-- set descriptions, that will be looked for in the map
	git_annex "describe" [".", "this repo"] @? "describe 1 failed"
	git_annex "describe" ["origin", "origin repo"] @? "describe 2 failed"
	-- --fast avoids it running graphviz, not a build dependency
	git_annex "map" ["--fast"] @? "map failed"

test_uninit :: Assertion
test_uninit = intmpclonerepo $ do
	git_annex "get" [] @? "get failed"
	annexed_present annexedfile
	_ <- git_annex "uninit" [] -- exit status not checked; does abnormal exit
	checkregularfile annexedfile
	doesDirectoryExist ".git" @? ".git vanished in uninit"

test_uninit_inbranch :: Assertion
test_uninit_inbranch = intmpclonerepoInDirect $ do
	boolSystem "git" [Params "checkout git-annex"] @? "git checkout git-annex"
	not <$> git_annex "uninit" [] @? "uninit failed to fail when git-annex branch was checked out"

test_upgrade :: Assertion
test_upgrade = intmpclonerepo $
	git_annex "upgrade" [] @? "upgrade from same version failed"

test_whereis :: Assertion
test_whereis = intmpclonerepo $ do
	annexed_notpresent annexedfile
	git_annex "whereis" [annexedfile] @? "whereis on non-present file failed"
	git_annex "untrust" ["origin"] @? "untrust failed"
	not <$> git_annex "whereis" [annexedfile] @? "whereis on non-present file only present in untrusted repo failed to fail"
	git_annex "get" [annexedfile] @? "get failed"
	annexed_present annexedfile
	git_annex "whereis" [annexedfile] @? "whereis on present file failed"

test_hook_remote :: Assertion
test_hook_remote = intmpclonerepo $ do
#ifndef mingw32_HOST_OS
	git_annex "initremote" (words "foo type=hook encryption=none hooktype=foo") @? "initremote failed"
	createDirectory dir
	git_config "annex.foo-store-hook" $
		"cp $ANNEX_FILE " ++ loc
	git_config "annex.foo-retrieve-hook" $
		"cp " ++ loc ++ " $ANNEX_FILE"
	git_config "annex.foo-remove-hook" $
		"rm -f " ++ loc
	git_config "annex.foo-checkpresent-hook" $
		"if [ -e " ++ loc ++ " ]; then echo $ANNEX_KEY; fi"
	git_annex "get" [annexedfile] @? "get of file failed"
	annexed_present annexedfile
	git_annex "copy" [annexedfile, "--to", "foo"] @? "copy --to hook remote failed"
	annexed_present annexedfile
	git_annex "drop" [annexedfile, "--numcopies=2"] @? "drop failed"
	annexed_notpresent annexedfile
	git_annex "move" [annexedfile, "--from", "foo"] @? "move --from hook remote failed"
	annexed_present annexedfile
	not <$> git_annex "drop" [annexedfile, "--numcopies=2"] @? "drop failed to fail"
	annexed_present annexedfile
  where
	dir = "dir"
	loc = dir ++ "/$ANNEX_KEY"
	git_config k v = boolSystem "git" [Param "config", Param k, Param v]
		@? "git config failed"
#else
	-- this test doesn't work in Windows TODO
	noop
#endif

test_directory_remote :: Assertion
test_directory_remote = intmpclonerepo $ do
	createDirectory "dir"
	git_annex "initremote" (words "foo type=directory encryption=none directory=dir") @? "initremote failed"
	git_annex "get" [annexedfile] @? "get of file failed"
	annexed_present annexedfile
	git_annex "copy" [annexedfile, "--to", "foo"] @? "copy --to directory remote failed"
	annexed_present annexedfile
	git_annex "drop" [annexedfile, "--numcopies=2"] @? "drop failed"
	annexed_notpresent annexedfile
	git_annex "move" [annexedfile, "--from", "foo"] @? "move --from directory remote failed"
	annexed_present annexedfile
	not <$> git_annex "drop" [annexedfile, "--numcopies=2"] @? "drop failed to fail"
	annexed_present annexedfile

test_rsync_remote :: Assertion
test_rsync_remote = intmpclonerepo $ do
	createDirectory "dir"
	git_annex "initremote" (words "foo type=rsync encryption=none rsyncurl=dir") @? "initremote failed"
	git_annex "get" [annexedfile] @? "get of file failed"
	annexed_present annexedfile
	git_annex "copy" [annexedfile, "--to", "foo"] @? "copy --to rsync remote failed"
	annexed_present annexedfile
	git_annex "drop" [annexedfile, "--numcopies=2"] @? "drop failed"
	annexed_notpresent annexedfile
	git_annex "move" [annexedfile, "--from", "foo"] @? "move --from rsync remote failed"
	annexed_present annexedfile
	not <$> git_annex "drop" [annexedfile, "--numcopies=2"] @? "drop failed to fail"
	annexed_present annexedfile

test_bup_remote :: Assertion
test_bup_remote = intmpclonerepo $ when Build.SysConfig.bup $ do
	dir <- absPath "dir" -- bup special remote needs an absolute path
	createDirectory dir
	git_annex "initremote" (words $ "foo type=bup encryption=none buprepo="++dir) @? "initremote failed"
	git_annex "get" [annexedfile] @? "get of file failed"
	annexed_present annexedfile
	git_annex "copy" [annexedfile, "--to", "foo"] @? "copy --to bup remote failed"
	annexed_present annexedfile
	git_annex "drop" [annexedfile, "--numcopies=2"] @? "drop failed"
	annexed_notpresent annexedfile
	git_annex "copy" [annexedfile, "--from", "foo"] @? "copy --from bup remote failed"
	annexed_present annexedfile
	git_annex "move" [annexedfile, "--from", "foo"] @? "move --from bup remote failed"
	annexed_present annexedfile

-- gpg is not a build dependency, so only test when it's available
test_crypto :: Assertion
#ifndef mingw32_HOST_OS
test_crypto = do
	testscheme "shared"
	testscheme "hybrid"
	testscheme "pubkey"
  where
	testscheme scheme = intmpclonerepo $ whenM (Utility.Path.inPath Utility.Gpg.gpgcmd) $ do
		Utility.Gpg.testTestHarness @? "test harness self-test failed"
		Utility.Gpg.testHarness $ do
			createDirectory "dir"
			let a cmd = git_annex cmd $
				[ "foo"
				, "type=directory"
				, "encryption=" ++ scheme
				, "directory=dir"
				, "highRandomQuality=false"
				] ++ if scheme `elem` ["hybrid","pubkey"]
					then ["keyid=" ++ Utility.Gpg.testKeyId]
					else []
			a "initremote" @? "initremote failed"
			not <$> a "initremote" @? "initremote failed to fail when run twice in a row"
			a "enableremote" @? "enableremote failed"
			a "enableremote" @? "enableremote failed when run twice in a row"
			git_annex "get" [annexedfile] @? "get of file failed"
			annexed_present annexedfile
			git_annex "copy" [annexedfile, "--to", "foo"] @? "copy --to encrypted remote failed"
			(c,k) <- annexeval $ do
				uuid <- Remote.nameToUUID "foo"
				rs <- Logs.Remote.readRemoteLog
				Just k <- Backend.lookupFile annexedfile
				return (fromJust $ M.lookup uuid rs, k)
			let key = if scheme `elem` ["hybrid","pubkey"]
					then Just $ Utility.Gpg.KeyIds [Utility.Gpg.testKeyId]
					else Nothing
			testEncryptedRemote scheme key c [k] @? "invalid crypto setup"
	
			annexed_present annexedfile
			git_annex "drop" [annexedfile, "--numcopies=2"] @? "drop failed"
			annexed_notpresent annexedfile
			git_annex "move" [annexedfile, "--from", "foo"] @? "move --from encrypted remote failed"
			annexed_present annexedfile
			not <$> git_annex "drop" [annexedfile, "--numcopies=2"] @? "drop failed to fail"
			annexed_present annexedfile
	{- Ensure the configuration complies with the encryption scheme, and
	 - that all keys are encrypted properly for the given directory remote. -}
	testEncryptedRemote scheme ks c keys = case Remote.Helper.Encryptable.extractCipher c of
		Just cip@Crypto.SharedCipher{} | scheme == "shared" && isNothing ks ->
			checkKeys cip Nothing
		Just cip@(Crypto.EncryptedCipher encipher v ks')
			| checkScheme v && keysMatch ks' ->
				checkKeys cip (Just v) <&&> checkCipher encipher ks'
		_ -> return False
	  where
		keysMatch (Utility.Gpg.KeyIds ks') =
			maybe False (\(Utility.Gpg.KeyIds ks2) ->
					sort (nub ks2) == sort (nub ks')) ks
		checkCipher encipher = Utility.Gpg.checkEncryptionStream encipher . Just
		checkScheme Types.Crypto.Hybrid = scheme == "hybrid"
		checkScheme Types.Crypto.PubKey = scheme == "pubkey"
		checkKeys cip mvariant = do
			cipher <- Crypto.decryptCipher cip
			files <- filterM doesFileExist $
				map ("dir" </>) $ concatMap (key2files cipher) keys
			return (not $ null files) <&&> allM (checkFile mvariant) files
		checkFile mvariant filename =
			Utility.Gpg.checkEncryptionFile filename $
				if mvariant == Just Types.Crypto.PubKey then ks else Nothing
		key2files cipher = Locations.keyPaths .
			Crypto.encryptKey Types.Crypto.HmacSha1 cipher
#else
test_crypto = putStrLn "gpg testing not implemented on Windows"
#endif

test_add_subdirs :: Assertion
test_add_subdirs = intmpclonerepo $ do
	createDirectory "dir"
	writeFile ("dir" </> "foo") $ "dir/" ++ content annexedfile
	git_annex "add" ["dir"] @? "add of subdir failed"

	{- Regression test for Windows bug where symlinks were not
	 - calculated correctly for files in subdirs. -}
	git_annex "sync" [] @? "sync failed"
	l <- annexeval $ decodeBS <$> Annex.CatFile.catObject (Git.Types.Ref "HEAD:dir/foo")
	"../.git/annex/" `isPrefixOf` l @? ("symlink from subdir to .git/annex is wrong: " ++ l)

	createDirectory "dir2"
	writeFile ("dir2" </> "foo") $ content annexedfile
	setCurrentDirectory "dir"
	git_annex "add" [".." </> "dir2"] @? "add of ../subdir failed"

test_addurl :: Assertion
test_addurl = intmpclonerepo $ do
	-- file:// only; this test suite should not hit the network
	f <- absPath "myurl"
	let url = replace "\\" "/" ("file:///" ++ dropDrive f)
	writeFile f "foo"
	git_annex "addurl" [url] @? ("addurl failed on " ++ url)
	let dest = "addurlurldest"
	git_annex "addurl" ["--file", dest, url] @? ("addurl failed on " ++ url ++ "  with --file")
	doesFileExist dest @? (dest ++ " missing after addurl --file")

-- This is equivilant to running git-annex, but it's all run in-process
-- so test coverage collection works.
git_annex :: String -> [String] -> IO Bool
git_annex command params = do
	-- catch all errors, including normally fatal errors
	r <- try run::IO (Either SomeException ())
	case r of
		Right _ -> return True
		Left _ -> return False
  where
	run = GitAnnex.run (command:"-q":params)

{- Runs git-annex and returns its output. -}
git_annex_output :: String -> [String] -> IO String
git_annex_output command params = do
	got <- Utility.Process.readProcess "git-annex" (command:params)
	-- Since the above is a separate process, code coverage stats are
	-- not gathered for things run in it.
	-- Run same command again, to get code coverage.
	_ <- git_annex command params
	return got

git_annex_expectoutput :: String -> [String] -> [String] -> IO ()
git_annex_expectoutput command params expected = do
	got <- lines <$> git_annex_output command params
	got == expected @? ("unexpected value running " ++ command ++ " " ++ show params ++ " -- got: " ++ show got ++ " expected: " ++ show expected)

-- Runs an action in the current annex. Note that shutdown actions
-- are not run; this should only be used for actions that query state.
annexeval :: Types.Annex a -> IO a
annexeval a = do
	s <- Annex.new =<< Git.CurrentRepo.get
	Annex.eval s $ do
		Annex.setOutput Types.Messages.QuietOutput
		a

innewrepo :: Assertion -> Assertion
innewrepo a = withgitrepo $ \r -> indir r a

inmainrepo :: Assertion -> Assertion
inmainrepo = indir mainrepodir

intmpclonerepo :: Assertion -> Assertion
intmpclonerepo a = withtmpclonerepo False $ \r -> indir r a

intmpclonerepoInDirect :: Assertion -> Assertion
intmpclonerepoInDirect a = intmpclonerepo $
	ifM isdirect
		( putStrLn "not supported in direct mode; skipping"
		, a
		)
  where
	isdirect = annexeval $ do
		Annex.Init.initialize Nothing
		Config.isDirect

checkRepo :: Types.Annex a -> FilePath -> IO a
checkRepo getval d = do
	s <- Annex.new =<< Git.Construct.fromPath d
	Annex.eval s getval

isInDirect :: FilePath -> IO Bool
isInDirect = checkRepo (not <$> Config.isDirect)

intmpbareclonerepo :: Assertion -> Assertion
intmpbareclonerepo a = withtmpclonerepo True $ \r -> indir r a

withtmpclonerepo :: Bool -> (FilePath -> Assertion) -> Assertion
withtmpclonerepo bare a = do
	dir <- tmprepodir
	bracket (clonerepo mainrepodir dir bare) cleanup a

disconnectOrigin :: Assertion
disconnectOrigin = boolSystem "git" [Params "remote rm origin"] @? "remote rm"

withgitrepo :: (FilePath -> Assertion) -> Assertion
withgitrepo = bracket (setuprepo mainrepodir) return

indir :: FilePath -> Assertion -> Assertion
indir dir a = do
	currdir <- getCurrentDirectory
	-- Assertion failures throw non-IO errors; catch
	-- any type of error and change back to currdir before
	-- rethrowing.
	r <- bracket_ (changeToTmpDir dir) (setCurrentDirectory currdir)
		(try a::IO (Either SomeException ()))
	case r of
		Right () -> return ()
		Left e -> throwM e

setuprepo :: FilePath -> IO FilePath
setuprepo dir = do
	cleanup dir
	ensuretmpdir
	boolSystem "git" [Params "init -q", File dir] @? "git init failed"
	configrepo dir
	return dir

-- clones are always done as local clones; we cannot test ssh clones
clonerepo :: FilePath -> FilePath -> Bool -> IO FilePath
clonerepo old new bare = do
	cleanup new
	ensuretmpdir
	let b = if bare then " --bare" else ""
	boolSystem "git" [Params ("clone -q" ++ b), File old, File new] @? "git clone failed"
	configrepo new
	indir new $
		git_annex "init" ["-q", new] @? "git annex init failed"
	unless bare $
		indir new $
			handleforcedirect
	return new

configrepo :: FilePath -> IO ()
configrepo dir = indir dir $ do
	-- ensure git is set up to let commits happen
	boolSystem "git" [Params "config user.name", Param "Test User"] @? "git config failed"
	boolSystem "git" [Params "config user.email test@example.com"] @? "git config failed"
	-- avoid signed commits by test suite
	boolSystem "git" [Params "config commit.gpgsign false"] @? "git config failed"

handleforcedirect :: IO ()
handleforcedirect = whenM ((==) "1" <$> Utility.Env.getEnvDefault "FORCEDIRECT" "") $
	git_annex "direct" ["-q"] @? "git annex direct failed"
	
ensuretmpdir :: IO ()
ensuretmpdir = do
	e <- doesDirectoryExist tmpdir
	unless e $
		createDirectory tmpdir

cleanup :: FilePath -> IO ()
cleanup = cleanup' False

cleanup' :: Bool -> FilePath -> IO ()
cleanup' final dir = whenM (doesDirectoryExist dir) $ do
	Command.Uninit.prepareRemoveAnnexDir dir
	-- This sometimes fails on Windows, due to some files
	-- being still opened by a subprocess.
	catchIO (removeDirectoryRecursive dir) $ \e ->
		when final $ do
			print e
			putStrLn "sleeping 10 seconds and will retry directory cleanup"
			Utility.ThreadScheduler.threadDelaySeconds (Utility.ThreadScheduler.Seconds 10)
			whenM (doesDirectoryExist dir) $
				removeDirectoryRecursive dir
	
checklink :: FilePath -> Assertion
checklink f = do
	s <- getSymbolicLinkStatus f
	-- in direct mode, it may be a symlink, or not, depending
	-- on whether the content is present.
	unlessM (annexeval Config.isDirect) $
		isSymbolicLink s @? f ++ " is not a symlink"

checkregularfile :: FilePath -> Assertion
checkregularfile f = do
	s <- getSymbolicLinkStatus f
	isRegularFile s @? f ++ " is not a normal file"
	return ()

checkcontent :: FilePath -> Assertion
checkcontent f = do
	c <- Utility.Exception.catchDefaultIO "could not read file" $ readFile f
	assertEqual ("checkcontent " ++ f) (content f) c

checkunwritable :: FilePath -> Assertion
checkunwritable f = unlessM (annexeval Config.isDirect) $ do
	-- Look at permissions bits rather than trying to write or
	-- using fileAccess because if run as root, any file can be
	-- modified despite permissions.
	s <- getFileStatus f
	let mode = fileMode s
	when (mode == mode `unionFileModes` ownerWriteMode) $
		assertFailure $ "able to modify annexed file's " ++ f ++ " content"

checkwritable :: FilePath -> Assertion
checkwritable f = do
	r <- tryIO $ writeFile f $ content f
	case r of
		Left _ -> assertFailure $ "unable to modify " ++ f
		Right _ -> return ()

checkdangling :: FilePath -> Assertion
checkdangling f = ifM (annexeval Config.crippledFileSystem)
	( return () -- probably no real symlinks to test
	, do
		r <- tryIO $ readFile f
		case r of
			Left _ -> return () -- expected; dangling link
			Right _ -> assertFailure $ f ++ " was not a dangling link as expected"
	)

checklocationlog :: FilePath -> Bool -> Assertion
checklocationlog f expected = do
	thisuuid <- annexeval Annex.UUID.getUUID
	r <- annexeval $ Backend.lookupFile f
	case r of
		Just k -> do
			uuids <- annexeval $ Remote.keyLocations k
			assertEqual ("bad content in location log for " ++ f ++ " key " ++ Types.Key.key2file k ++ " uuid " ++ show thisuuid)
				expected (thisuuid `elem` uuids)
		_ -> assertFailure $ f ++ " failed to look up key"

checkbackend :: FilePath -> Types.Backend -> Assertion
checkbackend file expected = do
	b <- annexeval $ maybe (return Nothing) (Backend.getBackend file) 
		=<< Backend.lookupFile file
	assertEqual ("backend for " ++ file) (Just expected) b

inlocationlog :: FilePath -> Assertion
inlocationlog f = checklocationlog f True

notinlocationlog :: FilePath -> Assertion
notinlocationlog f = checklocationlog f False

runchecks :: [FilePath -> Assertion] -> FilePath -> Assertion
runchecks [] _ = return ()
runchecks (a:as) f = do
	a f
	runchecks as f

annexed_notpresent :: FilePath -> Assertion
annexed_notpresent = runchecks
	[checklink, checkdangling, notinlocationlog]

annexed_present :: FilePath -> Assertion
annexed_present = runchecks
	[checklink, checkcontent, checkunwritable, inlocationlog]

unannexed :: FilePath -> Assertion
unannexed = runchecks [checkregularfile, checkcontent, checkwritable]

withTestEnv :: Bool -> TestTree -> TestTree
withTestEnv forcedirect = withResource prepare release . const
  where
	prepare = do
		setTestEnv forcedirect
		case tryIngredients [consoleTestReporter] mempty initTests of
			Nothing -> error "No tests found!?"
			Just act -> unlessM act $
				error "init tests failed! cannot continue"
		return ()
	release _ = cleanup' True tmpdir

setTestEnv :: Bool -> IO ()
setTestEnv forcedirect = do
	whenM (doesDirectoryExist tmpdir) $
		error $ "The temporary directory " ++ tmpdir ++ " already exists; cannot run test suite."

	currdir <- getCurrentDirectory
	p <- Utility.Env.getEnvDefault "PATH" ""

	mapM_ (\(var, val) -> Utility.Env.setEnv var val True)
		-- Ensure that the just-built git annex is used.
		[ ("PATH", currdir ++ [searchPathSeparator] ++ p)
		, ("TOPDIR", currdir)
		-- Avoid git complaining if it cannot determine the user's
		-- email address, or exploding if it doesn't know the user's
		-- name.
		, ("GIT_AUTHOR_EMAIL", "test@example.com")
		, ("GIT_AUTHOR_NAME", "git-annex test")
		, ("GIT_COMMITTER_EMAIL", "test@example.com")
		, ("GIT_COMMITTER_NAME", "git-annex test")
		-- force gpg into batch mode for the tests
		, ("GPG_BATCH", "1")
		, ("FORCEDIRECT", if forcedirect then "1" else "")
		]

changeToTmpDir :: FilePath -> IO ()
changeToTmpDir t = do
	topdir <- Utility.Env.getEnvDefault "TOPDIR" (error "TOPDIR not set")
	setCurrentDirectory $ topdir ++ "/" ++ t

tmpdir :: String
tmpdir = ".t"

mainrepodir :: FilePath
mainrepodir = tmpdir </> "repo"

tmprepodir :: IO FilePath
tmprepodir = go (0 :: Int)
  where
	go n = do
		let d = tmpdir </> "tmprepo" ++ show n
		ifM (doesDirectoryExist d)
			( go $ n + 1
			, return d
			)

annexedfile :: String
annexedfile = "foo"

wormannexedfile :: String
wormannexedfile = "apple"

sha1annexedfile :: String
sha1annexedfile = "sha1foo"

sha1annexedfiledup :: String
sha1annexedfiledup = "sha1foodup"

ingitfile :: String
ingitfile = "bar"

content :: FilePath -> String		
content f
	| f == annexedfile = "annexed file content"
	| f == ingitfile = "normal file content"
	| f == sha1annexedfile ="sha1 annexed file content"
	| f == sha1annexedfiledup = content sha1annexedfile
	| f == wormannexedfile = "worm annexed file content"
	| otherwise = "unknown file " ++ f

changecontent :: FilePath -> IO ()
changecontent f = writeFile f $ changedcontent f

changedcontent :: FilePath -> String
changedcontent f = content f ++ " (modified)"

backendSHA1 :: Types.Backend
backendSHA1 = backend_ "SHA1"

backendSHA256 :: Types.Backend
backendSHA256 = backend_ "SHA256"

backendWORM :: Types.Backend
backendWORM = backend_ "WORM"

backend_ :: String -> Types.Backend
backend_ = Backend.lookupBackendName
