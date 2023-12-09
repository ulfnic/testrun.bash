#!/usr/bin/env bash
# License: GNU Affero General Public License Version 3 (GNU AGPLv3), (c) 2023, Marc Gilligan <marcg@ulfnic.com>
set -o errexit
[[ $DEBUG ]] && set -x



help_doc() {
	cat 1>&2 <<-'HelpDoc'

		testrun.sh [OPTION]... [FILE]... [DIRECTORY]...

		A generic stand-alone script for handling execution and feedback for test files.

		Each DIRECTORY is assumed to only contain executable FILEs that are tests intended to
		be executed by this script.

		Null characters are allowed in stdin (see: --fork-stdin)


		Options:
		  -q|--quiet         Only the execution of tests and --help will write to stdout/stderr
		  -p|--params VAL    Contains IFS seperated param(s) to use with all test files, ex: -p '-c=3 -f /my/file'
		  -F|--fork-stdin    Write stdin into all tests
		  --dry-run          Print the filepaths to be executed

		  # -o and -i overwrite each other. They toggle a shared set of attributes.
		  -o|--halt-on       (failed_test|missing_test|non_exec|no_tests)
		  -i|--ignore        (failed_test|missing_test|non_exec|no_tests)
		  

		Defaults:
		  --halt-on missing_test
		  --halt-on no_tests
		  --ignore failed_test
		  --ignore non_exec


		Examples:

			# Run a test file and all tests recursively in two seperate directories
			testrun.sh my-test.sh /my/test/dir /my/other-test/dir

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
dry_run=
declare -A halt_on=(
	['missing_test']=1
	['no_tests']=1
)
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
		'--dry-run')
			dry_run=1 ;;
		'--halt-on'|'-o')
			shift; halt_on["$1"]=1 ;;
		'--ignore'|'-i')
			shift; halt_on["$1"]= ;;
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



# Validate parameter values
[[ ${#test_files[@]} ]] || help_doc 2

re='^(failed_test|missing_test|non_exec|no_tests)$'
for prop in "${!halt_on[@]}"; do
	[[ $prop =~ $re ]] || print_stderr 2 '%s\n' 'unrecognized value of --halt-on or --ignore: '"$prop"
done



# Validate paths provided by the user and extract the filepaths belonging to tests
shopt -s nullglob globstar
test_files=()
for test_path in "${test_paths[@]}"; do
	if [[ -x $test_path ]]; then

		if [[ -d $test_path ]]; then
			paths_tmp_arr=("$test_path/"**)
			for test_path_sub in "${paths_tmp_arr[@]}"; do
				[[ -x $test_path_sub ]] && [[ -f $test_path_sub ]] && test_files+=("$test_path_sub")
			done
		else
			test_files+=("$test_path")
		fi
		continue

	fi

	[[ ${halt_on['missing_test']} ]] && [[ ! -e $test_path ]] && print_stderr 4 '%s\n' 'test path does not exist: '"$test_path"
	[[ ${halt_on['non_exec']} ]] && print_stderr 4 '%s\n' 'test path is not executable: '"$test_path"
done
[[ ${halt_on['no_tests']} ]] && [[ ${#test_files[@]} == '0' ]] && print_stderr 4 '%s\n' 'no files to execute'



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
		[[ ${halt_on['failed_test']} ]] && exit 8
		test_failed=1
	fi
done



[[ $test_failed ]] && exit 8
exit 0



