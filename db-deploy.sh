#!/bin/bash

# Warning! Save this file as UTF8 without BOM, using Unix line endings (LF) only.


set -e # Exit immediately if a command exits with a non-zero status.
script=$(mktemp)

# try get path from param, otherwise use current directory
path=$PWD
if [ -d "$1" ]; then
    path=$1;
fi
dynpath="$path/dynamic"

# Echo used environment variables, makes debugging easier
echo "Using environment variables:"
echo " - DATABASE_NAME=$DATABASE_NAME"
echo " - SERVER_NAME=$SERVER_NAME"
echo " - SERVER_PORT=$SERVER_PORT"
echo " - SA_USERNAME=$SA_USERNAME"
echo " - SA_PASSWORD=$SA_PASSWORD"
echo " - DB_MODE=$DB_MODE"
echo " - ALLOW_MASTER=$ALLOW_MASTER"
echo "Using parameters:"
echo " - Base path=$path"
echo " - Dynamic path=$dynpath"


# used by sqlcmd, casing is important
export DatabaseName=$DATABASE_NAME

# use "sa" as username if 'SA_USERNAME' not defined
export SA_USERNAME="${SA_USERNAME:-sa}"

# if master access is not allowed (serverless cloud), fallback to DATABASE_NAME connection for system queries
export ALLOW_MASTER="${ALLOW_MASTER:-1}"


exec_scalar() {
	local dbname=$1
	if [ $ALLOW_MASTER -eq 0 ] && [ $dbname = 'master' ]; then
		dbname=$DATABASE_NAME
	fi
    /opt/mssql-tools/bin/sqlcmd -S $SERVER_NAME,$SERVER_PORT -U $SA_USERNAME -P $SA_PASSWORD -d $dbname -Q "set nocount on; $2" -W -h-1
}
embed_text() { 
	echo -e $1 >> $script 
}
embed_text_prepend() { 
	tmp=$(mktemp)
	cat <(echo -e $1) $script > $tmp
	mv $tmp $script
}
embed_log() {
	echo "PRINT '$1'" >> $script 
}
embed_go() {
	echo -e "\nGO\n" >> $script 
}
embed_file() {
	if [ -f "$1" ]; then
		if [ ${1: -4} == ".sql" ]; then
			echo "Embedding: $1"
			# Need to set working directory for sqlcmd to path of the script, so internally :r resolves properly)
			dir=${1%/*}
			file=${1##*/}
			
			embed_go
			embed_log "Executing: $1"
			embed_text ":setvar PATH \"$dir\""
			embed_text ":setvar FILE \"$file\""
			embed_go
			#cat "$1" >> $script
			
			# to be safe - remove BOM
			sed '1s/^\xEF\xBB\xBF//' $1 >> $script
			
			embed_go
		else
			echo "Skipping: $1"
		fi
	else
		echo "Not found: $1"
	fi
}
embed_folder() {
    for i in "$1"/*; do
        if [ -d "$i" ];then
            #echo "Dir: $i"
            embed_folder "$i"
        elif [ -f "$i" ]; then
            #echo "File: $i"
			embed_file "$i"
        fi
    done
}
embed_migration() {
	local from=$2
	local to=$3
    for i in "$1"/*; do
		# i is "/init/Scripts/Migration/*
		local rev=${i##*/}
		# 1. this must be a directory
		# 2. revision (last segment of the dir) - must be an integer
		# 3. revision must be in <from, to] range
        if [ -d "$i" ] && [ ! -z "${rev##*[!0-9]*}" ] && ((from < rev)) && (( rev <= to ));then
            embed_log "Running migration revision $rev from $i."
			embed_text ":setvar REVISION \"$rev\""
			embed_text ":setvar REVISION_FROM \"$from\""
			embed_text ":setvar REVISION_TO \"$to\""
            embed_folder "$i"
        fi
    done
}

get_rev_new() {
	props=$(cat $1)
	pat='<DatabaseRevision>(.*)</DatabaseRevision>'
	[[ $props =~ $pat ]]
	echo ${BASH_REMATCH[1]}
}


echo -n "Testing connection to $SERVER_NAME:$SERVER_PORT... "
exec_scalar 'master' 'select top 0 1'
echo "Success."

echo "Checking for database $DATABASE_NAME... "
dbexists=$(exec_scalar 'master' "select case when exists (select * from sys.databases where name = '$DATABASE_NAME') then 1 else 0 end")
dbempty=0
dbinit=0 # is initial deploy executed
rev_new=$(get_rev_new "$path/Directory.Build.props")
rev_new=${rev_new:-0}

# If database exists, and DB_MODE is "ForceNew" - drop it and recreate
if [ $dbexists -eq 1 ] && [ $DB_MODE = 'ForceNew' ]; then
	echo "Database $DATABASE_NAME exists, but DB_MODE=ForceNew, so will drop and recreate."
	exec_scalar 'master' "ALTER DATABASE [$DATABASE_NAME] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$DATABASE_NAME]"
	dbexists=0
	echo "Database $DATABASE_NAME dropped."
fi

# If database exists, but is empty - treat is as 
# Not dropping & recreating to support cloud variants where thats forbidden (eg Azure Sql Database)
if [ $dbexists -eq 1 ]; then
	# count schemas & tables - if any exist, assume db is not empty (lazy assumption, but good enough. Better way?)
	dbempty=$(exec_scalar $DATABASE_NAME "select case when exists(select * from sys.tables) then 0 else 1 end;");
fi

#echo "dbexists-$dbexists-"
#echo "dbempty-$dbempty-"

if [ $dbexists -eq 1 ] && [ $dbempty -eq 0 ]; then
	dbinit=0 # initial deployment will not be done

	echo "Database $DATABASE_NAME exists and is NOT empty."
	rev_cur=$(exec_scalar $DATABASE_NAME "if (object_id('Core.GetDatabaseRevision') is null) begin select 0 end else begin exec Core.GetDatabaseRevision end")
	rev_cur=${rev_cur:-0}
	
	if ((rev_cur >= rev_new)); then
		echo "Deployment skipped, current revision ($rev_cur) is greater or equal to new revision ($rev_new)."
	else
		echo "Creating deployment embedded script. Upgrading revision $rev_cur to $rev_new."
	
		embed_log "Starting deployment. Upgrading database revision $rev_cur -> $rev_new"
		embed_file "$path/Scripts/PreDeploy.sql"
		embed_go
		embed_migration "$path/Scripts/Migration" $rev_cur $rev_new
		embed_go
		embed_file "$path/Scripts/PostDeploy.sql"
		embed_go
		embed_text "exec Core.SetDatabaseRevision @Revision=$rev_new"
		embed_log "Database upgraded to revision $rev_new successfuly."
	fi
else
	dbinit=1 # initial deployment will be done

	if [ $dbempty -eq 1 ]; then
		# Database exists, but its empty... skip "create database", but proceed with initial deployment
		echo "Database $DATABASE_NAME exists, but is empty. Proceeding with initial deploy."
	else
		# If database does not exist, create it.
		# CREATE DATABASE statement must not be a part of final script, due to transactions
		echo "Database $DATABASE_NAME not found."
		exec_scalar 'master' "CREATE DATABASE [$DATABASE_NAME]"
		echo "Database $DATABASE_NAME created."
	fi
	
	embed_file "$path/Scripts/CreateDatabase.sql"
	embed_go
	embed_file "$path/Scripts/PostInitDeploy.sql"
	embed_go
	embed_file "$path/Scripts/PostDeploy.sql"
	embed_go
	embed_text "exec Core.SetDatabaseRevision @Revision=$rev_new"
	embed_log "Database upgraded to revision $rev_new successfuly."
fi


if [[ -s $script ]]; then

	# HEADER
	embed_text_prepend ":setvar ROOT \"$path\"\n:setvar SCRIPTS \"$path/Scripts\"\nGO\nSET NUMERIC_ROUNDABORT OFF\nGO\nSET ANSI_PADDING, ANSI_WARNINGS, CONCAT_NULL_YIELDS_NULL, ARITHABORT, QUOTED_IDENTIFIER, ANSI_NULLS ON\nGO\nSET XACT_ABORT ON\nBEGIN TRANSACTION\n"
	
	# FOOTER
	embed_text "\n\n\n--FOOTER--\n\nCOMMIT\n\nGO\nDECLARE @Success AS BIT\nSET @Success = 1\nSET NOEXEC OFF\nIF (@Success = 1) PRINT 'The database update succeeded'\nELSE BEGIN\nIF @@TRANCOUNT > 0 ROLLBACK TRANSACTION\nPRINT 'The database update failed'\nEND\nGO"

	echo -e '\n\033[0;33m==== Running embedded script in transaction ====\033[0m\n'
	echo "Script: $script..."
	/opt/mssql-tools/bin/sqlcmd -S $SERVER_NAME,$SERVER_PORT -U $SA_USERNAME -P $SA_PASSWORD -d $DATABASE_NAME -i $script
	echo -e '\n\033[0;33m==== Running embedded script in transaction complete ====\033[0m\n'
fi

# If new db was created, and dynamic path exists, execute dynamic scripts.
# This is usually used for testing, to populate tables with test/random data
# /init/dynamic folder is usually used, and is provided by docker readonly volume
if [ ${dbinit} -eq 1 ] && [ -d "$dynpath" ]; then
	script=$(mktemp)
	embed_text ":setvar ROOT \"$path\"\n:setvar SCRIPTS \"$path/Scripts\"\nGO\n"
	embed_folder $dynpath

	echo -e '\n\033[0;32m==== Running dynamic script ====\033[0m\n'
	echo "Script: $script..."
	/opt/mssql-tools/bin/sqlcmd -S $SERVER_NAME,$SERVER_PORT -U $SA_USERNAME -P $SA_PASSWORD -d $DATABASE_NAME -i $script
	echo -e '\n\033[0;32m==== Running dynamic script complete ====\033[0m\n'
fi
