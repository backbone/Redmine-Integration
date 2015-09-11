#!/bin/bash

# load config files
if [ -f /etc/gitorious_redmine ]; then
	source /etc/gitorious_redmine
elif [ -f ~/etc/gitorious_redmine ]; then
	source ~/etc/gitorious_redmine
else
	echo "Config file not found ;-("
	exit -1
fi

# === REMOVE ALL BROKEN REPOSITORY LINKS IN REDMINE MYSQL DATABASE ===
ALL_MYSQL_REPOS=`mysql -h$MYSQL_HOSTNAME -u $MYSQL_USER -e "SELECT url,root_url,id
                                                            FROM $REDMINE_MYSQL_DBNAME.repositories
                                                            WHERE type='Git'
                                                                  OR type='Repository::Git'" \
                                                            | grep -v tables_col|xargs|sed "s/ /\n/g"|tail -n+4`
repos_to_remove=
current_url=
current_root_url=
let n=0
for v in $ALL_MYSQL_REPOS; do
        let idx=n/3
        case $((n%3)) in
        0) current_url=$v;;
        1) current_root_url=$v;;
        2) [ ! -d $current_url -a ! -d $current_root_url ] && repos_to_remove="$repos_to_remove,$v";;
        esac
        let n++
done;
repos_to_remove=${repos_to_remove#,}
[ "$repos_to_remove" != "" ] && mysql -h$MYSQL_HOSTNAME -u $MYSQL_USER -e "DELETE FROM $REDMINE_MYSQL_DBNAME.repositories WHERE id IN ($repos_to_remove)"

# === REMOVE REPOSITORY LINKS WITH DIFFERENT PROJECT NAMES ===
REMOVE_IDS=`mysql -h$MYSQL_HOSTNAME -u $MYSQL_USER -e "SELECT $REDMINE_MYSQL_DBNAME.repositories.id
                                                       FROM $REDMINE_MYSQL_DBNAME.projects,
                                                            $REDMINE_MYSQL_DBNAME.repositories,
                                                            $GITORIOUS_MYSQL_DBNAME.repositories
                                                       WHERE ($REDMINE_MYSQL_DBNAME.repositories.url=CONCAT('$GITORIOUS_REPOS_PATH/',$GITORIOUS_MYSQL_DBNAME.repositories.hashed_path,'.git')
						              OR $REDMINE_MYSQL_DBNAME.repositories.root_url=CONCAT('$GITORIOUS_REPOS_PATH/',$GITORIOUS_MYSQL_DBNAME.repositories.hashed_path,'.git'))
							     AND $REDMINE_MYSQL_DBNAME.projects.name <> $GITORIOUS_MYSQL_DBNAME.repositories.name
						             AND $REDMINE_MYSQL_DBNAME.projects.id = $REDMINE_MYSQL_DBNAME.repositories.project_id
                                                       ;" \
                                                       | grep -v tables_col|xargs|sed "s/ /\n/g"|tail -n+2`
[ "$REMOVE_IDS" != "" ] && mysql -h$MYSQL_HOSTNAME -u $MYSQL_USER -e "DELETE FROM $REDMINE_MYSQL_DBNAME.repositories WHERE id IN ($REMOVE_IDS)"

# === GET DATA FROM GITORIOUS MYSQL BASE ===
roles_mysql_string=`echo $REDMINE_REQUIRED_ROLES | sed "s~\>~'~g ; s~\<~,'~g ; s~^,~~ ; s~ ~~g"`
REDMINE_ID_GITORIOUS_REPO=`mysql --default-character-set=utf8 -h$MYSQL_HOSTNAME -u $MYSQL_USER -e \
                        "SELECT DISTINCT $REDMINE_MYSQL_DBNAME.projects.id,$GITORIOUS_MYSQL_DBNAME.repositories.hashed_path
                         FROM $REDMINE_MYSQL_DBNAME.member_roles,
                              $REDMINE_MYSQL_DBNAME.members,
                              $REDMINE_MYSQL_DBNAME.projects,
                              $REDMINE_MYSQL_DBNAME.roles,
                              $REDMINE_MYSQL_DBNAME.users,
                              $REDMINE_MYSQL_DBNAME.email_addresses,
                              $GITORIOUS_MYSQL_DBNAME.repositories,
                              $GITORIOUS_MYSQL_DBNAME.roles,
                              $GITORIOUS_MYSQL_DBNAME.users
                         WHERE $REDMINE_MYSQL_DBNAME.member_roles.member_id=$REDMINE_MYSQL_DBNAME.members.id
                               AND $REDMINE_MYSQL_DBNAME.member_roles.role_id=$REDMINE_MYSQL_DBNAME.roles.id
                               AND $REDMINE_MYSQL_DBNAME.members.user_id=$REDMINE_MYSQL_DBNAME.users.id
                               AND $REDMINE_MYSQL_DBNAME.members.project_id=$REDMINE_MYSQL_DBNAME.projects.id
                               AND $REDMINE_MYSQL_DBNAME.projects.name=$GITORIOUS_MYSQL_DBNAME.repositories.name
                               AND $REDMINE_MYSQL_DBNAME.users.type='User'
                               AND $REDMINE_MYSQL_DBNAME.email_addresses.address=$GITORIOUS_MYSQL_DBNAME.users.email
                               AND $REDMINE_MYSQL_DBNAME.users.id=$REDMINE_MYSQL_DBNAME.email_addresses.user_id
                               AND $REDMINE_MYSQL_DBNAME.email_addresses.is_default='1'
                               AND $REDMINE_MYSQL_DBNAME.roles.name IN ($roles_mysql_string)
                               AND $GITORIOUS_MYSQL_DBNAME.repositories.user_id=$GITORIOUS_MYSQL_DBNAME.users.id;" \
                         | grep -v tables_col|xargs|sed "s/ /\n/g"|tail -n+3`

# add repositories paths to $REDMINE_MYSQL_DBNAME.repositories
redmine_project_id=
gitorious_path=
let n=0
for v in $REDMINE_ID_GITORIOUS_REPO; do
	let idx=n/2
	case $((n%2)) in
	0) redmine_project_id=$v ;;
	1) gitorious_path=$GITORIOUS_REPOS_PATH/$v.git 
		# Test for already present repo
	        ALREADY_EXIST=`mysql -h$MYSQL_HOSTNAME -u $MYSQL_USER -e "SELECT id
	                                                                  FROM $REDMINE_MYSQL_DBNAME.repositories
	                                                                  WHERE project_id='$redmine_project_id'
	                                                                        OR url='$gitorious_path'
	                                                                        OR root_url='$gitorious_path'" \
	                                                                  | grep -v tables_col|xargs|sed "s/ /\n/g"|tail -n+2`
	        if [ "" == "$ALREADY_EXIST" ]; then
			# insert to $REDMINE_MYSQL_DBNAME.repositories
			echo "insert $redmine_project_id: $gitorious_path"
			mysql -h$MYSQL_HOSTNAME -u $MYSQL_USER -e "INSERT INTO $REDMINE_MYSQL_DBNAME.repositories(project_id,
			                                                                                        url,
			                                                                                        root_url,
			                                                                                        type,
			                                                                                        path_encoding,
			                                                                                        is_default)
			                                           VALUES('$redmine_project_id',
			                                                  '$gitorious_path',
			                                                  '$gitorious_path',
			                                                  'Repository::Git',
			                                                  '',
			                                                  1)"
		fi
	;;
	esac
	let n++
done
