#!/bin/bash

# load config files
if [ -f /etc/gitorious_chiliproject ]; then
	source /etc/gitorious_chiliproject
elif [ -f ~/etc/gitorious_chiliproject ]; then
	source ~/etc/gitorious_chiliproject
else
	echo "Config file not found ;-("
	exit -1
fi

# === REMOVE ALL BROKEN REPOSITORY LINKS IN CHILIPROJECT MYSQL DATABASE ===
ALL_MYSQL_REPOS=`mysql -h$MYSQL_HOSTNAME -u $MYSQL_USER -e "SELECT url,root_url,id
                                                            FROM $CHILI_MYSQL_DBNAME.repositories
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
[ "$repos_to_remove" != "" ] && mysql -h$MYSQL_HOSTNAME -u $MYSQL_USER -e "DELETE FROM $CHILI_MYSQL_DBNAME.repositories WHERE id IN ($repos_to_remove)"

# === REMOVE REPOSITORY LINKS WITH DIFFERENT PROJECT NAMES ===
REMOVE_IDS=`mysql -h$MYSQL_HOSTNAME -u $MYSQL_USER -e "SELECT $CHILI_MYSQL_DBNAME.repositories.id
                                                       FROM $CHILI_MYSQL_DBNAME.projects,
                                                            $CHILI_MYSQL_DBNAME.repositories,
                                                            $GITORIOUS_MYSQL_DBNAME.repositories
                                                       WHERE ($CHILI_MYSQL_DBNAME.repositories.url=CONCAT('$GITORIOUS_REPOS_PATH/',$GITORIOUS_MYSQL_DBNAME.repositories.hashed_path,'.git')
						              OR $CHILI_MYSQL_DBNAME.repositories.root_url=CONCAT('$GITORIOUS_REPOS_PATH/',$GITORIOUS_MYSQL_DBNAME.repositories.hashed_path,'.git'))
							     AND $CHILI_MYSQL_DBNAME.projects.name <> $GITORIOUS_MYSQL_DBNAME.repositories.name
						             AND $CHILI_MYSQL_DBNAME.projects.id = $CHILI_MYSQL_DBNAME.repositories.project_id
                                                       ;" \
                                                       | grep -v tables_col|xargs|sed "s/ /\n/g"|tail -n+2`
[ "$REMOVE_IDS" != "" ] && mysql -h$MYSQL_HOSTNAME -u $MYSQL_USER -e "DELETE FROM $CHILI_MYSQL_DBNAME.repositories WHERE id IN ($REMOVE_IDS)"

# === GET DATA FROM GITORIOUS MYSQL BASE ===
roles_mysql_string=`echo $CHILI_REQUIRED_ROLES | sed "s~\>~'~g ; s~\<~,'~g ; s~^,~~ ; s~ ~~g"`
CHILI_ID_GITORIOUS_REPO=`mysql --default-character-set=utf8 -h$MYSQL_HOSTNAME -u $MYSQL_USER -e \
                        "SELECT DISTINCT $CHILI_MYSQL_DBNAME.projects.id,$GITORIOUS_MYSQL_DBNAME.repositories.hashed_path
                         FROM $CHILI_MYSQL_DBNAME.member_roles,
                              $CHILI_MYSQL_DBNAME.members,
                              $CHILI_MYSQL_DBNAME.projects,
                              $CHILI_MYSQL_DBNAME.roles,
                              $CHILI_MYSQL_DBNAME.users,
                              $GITORIOUS_MYSQL_DBNAME.repositories,
                              $GITORIOUS_MYSQL_DBNAME.roles,
                              $GITORIOUS_MYSQL_DBNAME.users
                         WHERE $CHILI_MYSQL_DBNAME.member_roles.member_id=$CHILI_MYSQL_DBNAME.members.id
                               AND $CHILI_MYSQL_DBNAME.member_roles.role_id=$CHILI_MYSQL_DBNAME.roles.id
                               AND $CHILI_MYSQL_DBNAME.members.user_id=$CHILI_MYSQL_DBNAME.users.id
                               AND $CHILI_MYSQL_DBNAME.members.project_id=$CHILI_MYSQL_DBNAME.projects.id
                               AND $CHILI_MYSQL_DBNAME.projects.name=$GITORIOUS_MYSQL_DBNAME.repositories.name
                               AND $CHILI_MYSQL_DBNAME.users.type='User'
                               AND $CHILI_MYSQL_DBNAME.users.mail=$GITORIOUS_MYSQL_DBNAME.users.email
                               AND $CHILI_MYSQL_DBNAME.roles.name IN ($roles_mysql_string)
                               AND $GITORIOUS_MYSQL_DBNAME.repositories.user_id=$GITORIOUS_MYSQL_DBNAME.users.id;" \
                         | grep -v tables_col|xargs|sed "s/ /\n/g"|tail -n+3`

# add repositories paths to $CHILI_MYSQL_DBNAME.repositories
chili_project_id=
gitorious_path=
let n=0
for v in $CHILI_ID_GITORIOUS_REPO; do
	let idx=n/2
	case $((n%2)) in
	0) chili_project_id=$v ;;
	1) gitorious_path=$GITORIOUS_REPOS_PATH/$v.git 
		# Test for already present repo
	        ALREADY_EXIST=`mysql -h$MYSQL_HOSTNAME -u $MYSQL_USER -e "SELECT id
	                                                                  FROM $CHILI_MYSQL_DBNAME.repositories
	                                                                  WHERE project_id='$chili_project_id'
	                                                                        OR url='$gitorious_path'
	                                                                        OR root_url='$gitorious_path'" \
	                                                                  | grep -v tables_col|xargs|sed "s/ /\n/g"|tail -n+2`
	        if [ "" == "$ALREADY_EXIST" ]; then
			# insert to $CHILI_MYSQL_DBNAME.repositories
			echo "insert $chili_project_id: $gitorious_path"
			mysql -h$MYSQL_HOSTNAME -u $MYSQL_USER -e "INSERT INTO $CHILI_MYSQL_DBNAME.repositories(project_id,
			                                                                                        url,
			                                                                                        root_url,
			                                                                                        type,
			                                                                                        path_encoding,
			                                                                                        is_default)
			                                           VALUES('$chili_project_id',
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
