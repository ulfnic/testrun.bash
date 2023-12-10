#!/usr/bin/env bash
# License: GNU Affero General Public License Version 3 (GNU AGPLv3), (c) 2023, Marc Gilligan <marcg@ulfnic.com>
set -o errexit
[[ $DEBUG ]] && set -x



help_doc() {
	cat 1>&2 <<-'HelpDoc'

		testrun.sh [OPTION]... [test-FILE]... [DIRECTORY]...

		A stand-alone script for running tests intended to be included inline within projects or installed on a host system.

		test-FILEs must be executable and begin with 'test-', each DIRECTORY is searched recursively for test-FILEs

		If the directory containing this script is named 'tests':
		  - --app-root-dir defaults to the directory one level up from this script if it contains a .git folder.
		  - Test paths default to the sub-directories of the directory containing this script.

		If an app directory is specified or it has a default, it becomes the active directory before tests are run.


		Options:
		  -q|--quiet                Redirect non-errors and all test output to /dev/null
		  -S|--silence-tests 1|2|b  Redirect test stdout (1), stderr (2), or both (b) to /dev/null
		  -p|--params VAL           IFS seperated parameters to use with all test files
		  -F|--fork-stdin           Write stdin into all tests
		  -e|--fail-exit            Exit on first failed test
		  -a|--app-root-dir         Root directory of the application to cd into prior to running tests
		  --dry-run                 Print the filepaths to be executed


		Examples:

			# Run a test file and all tests recursively in two seperate directories
			testrun.sh test-lasers /my/tests /my/other/tests

			# Fork stdin and parameters across all tests
			printf '%s\n' "hello all tests" | testrun.sh -F -p '-c=3 -f /my/file' /my/tests


		Exit status:
		  0    success
		  1    general error
		  2    failed parameter validation
		  4    failed validation of test files to be run
		  8    one or more tests returned an exit code greater than 0

	HelpDoc
	[[ $1 ]] && exit "$1"
}



# Define defaults
quiet=
test_params=()
fork_stdin=
fail_exit=
app_root_dir=
dry_run=
script_in_tests_folder=
tmp_dir='/tmp'
test_stdout='/dev/fd/1'
test_stderr='/dev/fd/2'



print_stderr() {
	if [[ $1 == '0' ]]; then
		[[ $2 ]] && [[ ! $quiet ]] && printf "$2" "${@:3}" 1>&2 || :
	else
		[[ $2 ]] && printf '%s'"$2" "ERROR: ${0##*/}, " "${@:3}" 1>&2 || :
		exit "$1"
	fi
}



# Read params
test_paths=()
while [[ $1 ]]; do
	case $1 in
		'--quiet'|'-q')
			quiet=1
			test_stdout='/dev/null'
			test_stderr='/dev/null'
			;;
		'--silence-tests'|'-S')
			shift; case $1 in
				'1'|'b') test_stdout='/dev/null' ;;& '1') ;;
				'2'|'b') test_stderr='/dev/null' ;;
				*) print_stderr 2 '%s\n' 'unrecognized silence type: '"$1"
			esac
			;;
		'--params'|'-p')
			shift; test_params=($1) ;;
		'--fork-stdin'|'-F')
			fork_stdin=1 ;;
		'--fail-exit'|'-e')
			fail_exit=1 ;;
		'--app-root-dir'|'-a')
			shift; app_root_dir=$1 ;;
		'--dry-run')
			dry_run=1 ;;
		'--help'|'-h')
			help_doc 0 ;;
		'--')
			break ;;
		'-'*)
			print_stderr 2 '%s\n' 'unrecognized parameter: '"$1" ;;
		*)
			test_paths+=("$1") ;;
	esac
	shift
done
test_paths+=("$@")



# Determine absolute directory of this script
script_dir=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)

# If the directory in which the script resides is named 'tests'
if [[ ${script_dir##*/} == 'tests' ]]; then
	script_in_tests_folder=1

	# If app_root_dir is unspecified the directory one level up is used if it contains a .git file
	if [[ ! $app_root_dir ]]; then
		app_root_dir_candidate=${script_dir%/*}
		: ${app_root_dir_candidate:='/'}
		[[ -d $app_root_dir_candidate'/.git' ]] && app_root_dir=$app_root_dir_candidate
	fi

	# If no test paths are specified, the sub-directories of the script's directory become the test paths
	[[ ${#test_paths[@]} == 0 ]] && test_paths=("$script_dir"'/'*'/')

else
	[[ ${#test_paths[@]} == 0 ]] && print_stderr 2 '%s\n' 'no test paths given'

fi



# Validate paths provided by the user and extract the filepaths belonging to tests
shopt -s nullglob globstar
test_files=()
for test_path in "${test_paths[@]}"; do

	[[ -e $test_path ]] || print_stderr 4 '%s\n' 'test path does not exist: '"$test_path"
	[[ -x $test_path ]] || print_stderr 4 '%s\n' 'test path is not executable: '"$test_path"

	if [[ -d $test_path ]]; then
		# Convert directory to absolute path
		test_path=$(cd -- "$test_path" && pwd)

		paths_tmp_arr=("$test_path/"**'/test-'*)
		for test_path_sub in "${paths_tmp_arr[@]}"; do
			[[ -x $test_path_sub ]] && [[ -f $test_path_sub ]] && test_files+=("$test_path_sub")
		done
		continue
	fi

	# Convert file to absolute path
	test_path_file=${test_path##*/}
	if [[ $test_path_file == $test_path ]]; then
		test_path=$PWD'/'$test_path_file
	else
		test_path_dir=${test_path%/*}
		test_path_dir=$(cd -- "$test_path_dir" && pwd)
		test_path=$test_path_dir'/'$test_path_file
	fi

	[[ ${test_path##*/} == 'test-'* ]] || print_stderr 4 '%s\n' 'test filenames must begin with test- :'"$test_path"
	test_files+=("$test_path")
	
done
[[ ${#test_files[@]} == '0' ]] && print_stderr 4 '%s\n' 'no tests to execute'



# Complete a dry run printing the filepaths to be executed
if [[ $dry_run ]]; then
	for test_path in "${test_files[@]}"; do
		test_path_print=$test_path
		[[ $script_in_tests_folder ]] && [[ $test_path_print == "$script_dir"/* ]] && test_path_print=${test_path_print:${#script_dir}+1}
		printf -v test_params_print '%q ' "${test_params[@]}"
		printf '%q %s\n' "$test_path_print" "$test_params_print"
	done
	exit 0
fi



# If --fork-stdin is in use, write stdin to a permissioned temp file that's removed on EXIT
if [[ $fork_stdin ]]; then
	[[ -d $tmp_dir ]] || print_stderr 1 '%s\n' 'temp directory does not exist: '"$tmp_dir"

	stdin_cache_path=$tmp_dir'/test-run__in_'$$'_'${EPOCHSECONDS:=$(date +%s)}

	umask_orig=$(umask); umask 0077
	cat /dev/fd/0 > "$stdin_cache_path"
	umask "$umask_orig"

	trap '[[ -e $stdin_cache_path ]] && rm $stdin_cache_path' EXIT
fi



# Execute tests
cd -- "$app_root_dir"
test_failed=
for test_path in "${test_files[@]}"; do

	if [[ $fork_stdin ]]; then
		"$test_path" "${test_params[@]}" 1>"$test_stdout" 2>"$test_stderr" < cat "$tmp_dir"'/stdin' && exit_code=$? || exit_code=$?
	else
		"$test_path" "${test_params[@]}" 1>"$test_stdout" 2>"$test_stderr" && exit_code=$? || exit_code=$?
	fi

	test_path_print=$test_path
	[[ $script_in_tests_folder ]] && [[ $test_path_print == "$script_dir"/* ]] && test_path_print=${test_path_print:${#script_dir}+1}

	if [[ $exit_code == '0' ]]; then
		print_stderr 0 '\e[32m%s\e[0m %s\n' "[${exit_code}]" "$test_path_print"

	else
		print_stderr 0 '\e[31m%s\e[0m %s\n' "[${exit_code}]" "$test_path_print"
		[[ $fail_exit ]] && exit 8
		test_failed=1
	fi
done



[[ $test_failed ]] && exit 8
exit 0



