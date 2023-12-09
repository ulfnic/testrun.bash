#!/usr/bin/env bash
# License: GNU Affero General Public License Version 3 (GNU AGPLv3), (c) 2023, Marc Gilligan <marcg@ulfnic.com>
set -o errexit
[[ $DEBUG ]] && set -x



help_doc() {
	cat 1>&2 <<-'HelpDoc'

		testrun.sh [OPTION]... [test-FILE]... [DIRECTORY]...

		A generic stand-alone script for handling execution and feedback for test files.

		FILEs must be executable and begin with 'test-'

		Each DIRECTORY is searched recursively for executable FILEs beginning with 'test-'

		Null characters are allowed in stdin (see: --fork-stdin)


		Options:
		  -q|--quiet         Only the execution of tests and --help will write to stdout/stderr
		  -p|--params VAL    Contains IFS seperated param(s) to use with all test files, ex: -p '-c=3 -f /my/file'
		  -F|--fork-stdin    Write stdin into all tests
		  -e|--fail-exit     Exit on first failed test
		  --dry-run          Print the filepaths to be executed


		Examples:

			# Run a test file and all tests recursively in two seperate directories
			testrun.sh test-lasers /my/tests /my/other/tests

			# Fork stdin across all tests
			printf '%s\n' "hello all tests" | testrun.sh -f ./tests


		Exit status:
		  0    success
		  1    unmanaged error
		  2    failed parameter validation
		  4    failed validation of test files to be run
		  8    one or more tests returned an exit code greater than 0

	HelpDoc
	[[ $1 ]] && exit "$1"
}
[[ $1 ]] || help_doc 0



# Define defaults
quiet=
test_params=()
fork_stdin=
fail_exit=
dry_run=
tmp_dir='/tmp'



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
			quiet=1 ;;
		'--params'|'-p')
			shift; test_params=($1) ;;
		'--fork-stdin'|'-F')
			fork_stdin=1 ;;
		'--fail-exit'|'-e')
			fail_exit=1 ;;
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



# Validate values
[[ ${#test_files[@]} ]] || help_doc 2
[[ -d $tmp_dir ]] || printf '%s\n' 'temp directory doesnt exist: '"$tmp_dir"



# Validate paths provided by the user and extract the filepaths belonging to tests
shopt -s nullglob globstar
test_files=()
for test_path in "${test_paths[@]}"; do

	[[ -e $test_path ]] || print_stderr 4 '%s\n' 'test path does not exist: '"$test_path"
	[[ -x $test_path ]] || print_stderr 4 '%s\n' 'test path is not executable: '"$test_path"

	if [[ -d $test_path ]]; then
		paths_tmp_arr=("$test_path/"**'/test-'*)
		for test_path_sub in "${paths_tmp_arr[@]}"; do
			[[ -x $test_path_sub ]] && [[ -f $test_path_sub ]] && test_files+=("$test_path_sub")
		done
		continue
	fi

	[[ ${test_path##*/} == 'test-'* ]] || print_stderr 1 '%s\n' 'test files must being with test-'
	test_files+=("$test_path")
	
done
[[ ${#test_files[@]} == '0' ]] && print_stderr 4 '%s\n' 'no tests to execute'



# Complete a dry run printing the filepaths to be executed
if [[ $dry_run ]]; then
	for test_path in "${test_files[@]}"; do
		printf -v test_params_print '%q ' "${test_params[@]}"
		printf '%q %s\n' "$test_path" "$test_params_print"
	done
	exit 0
fi



# If --fork-stdin is in use, write stdin to a temp file so it can be written to the stdin of each test
if [[ $fork_stdin ]]; then
	stdin_cache_path=$tmp_dir'/test-run__in_'$$'_'$EPOCHSECONDS

	umask_orig=$(umask); umask 0077
	cat /dev/fd/0 > "$stdin_cache_path"
	umask "$umask_orig"

	trap '[[ -e $stdin_cache_path ]] && rm $stdin_cache_path' EXIT
fi



# Execute tests
test_failed=
for test_path in "${test_files[@]}"; do

	if [[ $fork_stdin ]]; then
		"$test_path" "${test_params[@]}" < cat "$tmp_dir"'/stdin' && exit_code=$? || exit_code=$?
	else
		"$test_path" "${test_params[@]}" && exit_code=$? || exit_code=$?
	fi

	if [[ $exit_code == '0' ]]; then
		print_stderr 0 '\e[32m%s\e[0m %s\n' "[${exit_code}]" "${test_path@Q}"

	else
		print_stderr 0 '\e[31m%s\e[0m %s\n' "[${exit_code}]" "${test_path@Q}"
		[[ $fail_exit ]] && exit 8
		test_failed=1
	fi
done



[[ $test_failed ]] && exit 8
exit 0



