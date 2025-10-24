#!/usr/bin/env bash
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
		  -q|--quiet                 Redirect non-errors and all test output to /dev/null
		  -S|--silence-tests 1|2|b   Redirect test stdout (1), stderr (2), or both (b) to /dev/null
		  -p|--params VAL            IFS seperated parameters to use with all test files
		  -F|--fork-stdin            Write stdin into all tests
		  -e|--fail-exit             Exit on first failed test
		  -a|--app-root-dir          Root directory of the application to cd into prior to running tests
		  -l|--localize-path-output  Localize test paths to the tests/ directory during output
		  -L|--absolute-path-output  Use absolute paths for tests during output
		  --dry-run                  Print the filepaths to be executed


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
app_root_dir_absolute=
test_path_print_as='local'
dry_run=
script_in_tests_folder=
tests_dir_absolute=
tmp_dir='/tmp'
test_stdout='/dev/fd/1'
test_stderr='/dev/fd/2'
readonly local_dir=$PWD
readonly local_dir_len=${#local_dir}



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
		'--app-root-dir'|'-a')
			shift; app_root_dir=$1 ;;
		'--localize-path-output'|'-l')
			test_path_print_as='test-local' ;;
		'--absolute-path-output'|'-L')
			test_path_print_as='absolute' ;;
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



# Determine absolute directories for the script and app root
script_dir_absolute=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)
[[ ${script_dir_absolute##*/} == 'tests' ]] && script_in_tests_folder=1
[[ $app_root_dir ]] && app_root_dir_absolute=$(cd -- "$app_root_dir" && pwd)



# If an app root directory was specified, attempt to determine the location of a tests/ directory,
# and if no tests are specified, add tests from that directory.
if [[ $app_root_dir_absolute ]]; then

	# If this script resides in a tests/ directory
	if [[ $script_in_tests_folder ]]; then
		tests_dir_absolute=$script_dir_absolute
		[[ ${#test_paths[@]} == 0 ]] && test_paths=("$tests_dir_absolute"'/'*'/')

	# If the script isn't in a tests/ directory but the app root directory has a tests/ directory.
	elif [[ -d $app_root_dir_absolute'/tests' ]]; then
		tests_dir_absolute=$app_root_dir_absolute'/tests'
		[[ ${#test_paths[@]} == 0 ]] && test_paths=("$tests_dir_absolute"'/'*'/')
	fi



# If an app root was not specified and the script resides in a tests/ directory, add tests from that
# directory if none are specified, and attempt to determine the location of the app's root directory.
elif [[ $script_in_tests_folder ]]; then
	tests_dir_absolute=$script_dir_absolute

	# If no test paths are specified, the sub-directories of the script's directory become the test paths.
	[[ ${#test_paths[@]} == 0 ]] && test_paths=("$tests_dir_absolute"'/'*'/')

	# If the directory one level up from the script directory contains a .git/ or app_root/.git/
	# directory, set the parent of the .git directory as the app's root directory.
	app_root_dir_candidate=${script_dir_absolute%/*}
	: ${app_root_dir_candidate:='/'}
	if [[ -d $app_root_dir_candidate'/.git' ]]; then
		app_root_dir_absolute=$app_root_dir_candidate
	elif [[ -d $app_root_dir_candidate'/app_root/.git' ]]; then
		app_root_dir_absolute=$app_root_dir_candidate'/app_root'
	fi

fi



readonly tests_dir_absolute
[[ $tests_dir_absolute_len ]] && readonly tests_dir_absolute_len=${#tests_dir_absolute}



# Validate paths provided by the user and extract the filepaths belonging to tests
[[ ${#test_paths[@]} == 0 ]] && print_stderr 2 '%s\n' 'no test paths given'
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



format_test_path_print() {
	# Variable 'test_path_print' is expected to contain the absolute path of a test file
	case $test_path_print_as in
		'local')
			[[ $test_path_print == "$local_dir"/* ]] && test_path_print='./'${test_path_print:local_dir_len+1} ;;
		'test-local')
			[[ $test_path_print == "$tests_dir_absolute"/* ]] && test_path_print=${test_path_print:tests_dir_absolute_len+1} ;;
	esac
}



# Complete a dry run printing the filepaths to be executed
if [[ $dry_run ]]; then
	[[ ${#test_params[@]} == 0 ]] && params_exist= || params_exist=1
	for test_path in "${test_files[@]}"; do

		test_path_print=$test_path
		format_test_path_print

		printf '%q' "$test_path_print"
		[[ $params_exist ]] && printf ' %q' "${test_params[@]}"
		printf '\n'
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
cd -- "$app_root_dir_absolute"
test_failed=
for test_path in "${test_files[@]}"; do

	if [[ $fork_stdin ]]; then
		"$test_path" "${test_params[@]}" 1>"$test_stdout" 2>"$test_stderr" < cat "$tmp_dir"'/stdin' && exit_code=$? || exit_code=$?
	else
		"$test_path" "${test_params[@]}" 1>"$test_stdout" 2>"$test_stderr" && exit_code=$? || exit_code=$?
	fi


	test_path_print=$test_path
	format_test_path_print


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



