#!/usr/bin/env bash
source /usr/local/bin/docker-entrypoint.sh
# Execute sql script, passed via stdin (or -f flag of pqsl)
# usage: docker_process_sql [psql-cli-args]
#    ie: docker_process_sql --dbname=mydb <<<'INSERT ...'
#    ie: docker_process_sql -f my-file.sql
#    ie: docker_process_sql <my-file.sql
docker_process_sql() {
	local query_runner=( psql -a -b -e -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --no-password )
	if [ -n "$POSTGRES_DB" ]; then
		query_runner+=( --dbname "$POSTGRES_DB" )
	fi

	"${query_runner[@]}" "$@"
}
main() {
	# if first arg looks like a flag, assume we want to run postgres server
	if [ "${1:0:1}" = '-' ]; then
		set -- postgres "$@"
	fi

	if [ "$1" = 'postgres' ] && ! _pg_want_help "$@"; then
		docker_setup_env
		# setup data directories and permissions (when run as root)
		docker_create_db_directories
		if [ "$(id -u)" = '0' ]; then
			# then restart script as postgres user
			exec gosu postgres "$BASH_SOURCE" "$@"
		fi

		# only run initialization on an empty data directory
		if [ -z "$DATABASE_ALREADY_EXISTS" ]; then
			docker_verify_minimum_env

			if [ -z "$POSTGRES_NON_ADMIN_USERNAME" ]; then
			    echo "evn var POSTGRES_NON_ADMIN_USERNAME not set"
				exit 1
			fi

			if [ -z "$POSTGRES_NON_ADMIN_PASSWORD" ]; then
			    echo "evn var POSTGRES_NON_ADMIN_PASSWORD not set"
				exit 1
			fi

			# check dir permissions to reduce likelihood of half-initialized database
			ls /docker-entrypoint-initdb.d/ > /dev/null

			docker_init_database_dir
			pg_setup_hba_conf
		fi
        # PGPASSWORD is required for psql when authentication is required for 'local' connections via pg_hba.conf and is otherwise harmless
		# e.g. when '--auth=md5' or '--auth-local=md5' is used in POSTGRES_INITDB_ARGS
		export PGPASSWORD="${PGPASSWORD:-$POSTGRES_PASSWORD}"
		docker_temp_server_start "$@"

		if [ -z "$DATABASE_ALREADY_EXISTS" ]; then
			docker_setup_db
			docker_process_sql <<< "
			DO \$do\$ BEGIN IF NOT EXISTS (
     			SELECT
     			FROM pg_catalog.pg_roles -- SELECT list can be empty for this
     			WHERE rolname = '$POSTGRES_NON_ADMIN_USERNAME'
			) THEN CREATE ROLE $POSTGRES_NON_ADMIN_USERNAME LOGIN PASSWORD '$POSTGRES_NON_ADMIN_PASSWORD';
			END IF;
			END \$do\$;"
		fi

		docker_process_init_files /docker-entrypoint-initdb.d/*

		docker_temp_server_stop
		unset PGPASSWORD
		unset POSTGRES_NON_ADMIN_PASSWORD
	fi

	exec "$@"
}

main "$@"