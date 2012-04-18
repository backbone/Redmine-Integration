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
ALL_MYSQL_REPOS=`mysql -h$CHILI_MYSQL_HOSTNAME -u $CHILI_MYSQL_USER -e "SELECT url,root_url,id FROM $CHILI_MYSQL_DBNAME.repositories WHERE type='Git' OR type='Repository::Git'" | grep -v tables_col|xargs|sed "s/ /\n/g"|tail -n+4`
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
[ "$repos_to_remove" != "" ] && mysql -h$CHILI_MYSQL_HOSTNAME -u $CHILI_MYSQL_USER -e "DELETE FROM $CHILI_MYSQL_DBNAME.repositories WHERE id IN ($repos_to_remove)"

# === GET DATA FROM GITORIOUS MYSQL BASE ===
CHILI_ID_GITORIOUS_REPO=`mysql -h$GITORIOUS_MYSQL_HOSTNAME -u $GITORIOUS_MYSQL_USER -e \
                        "SELECT DISTINCT redmine.projects.id,gitorious.repositories.hashed_path
                         FROM redmine.member_roles,redmine.members,redmine.projects,redmine.roles,redmine.users,gitorious.repositories,gitorious.roles,gitorious.users
                         WHERE redmine.member_roles.member_id=redmine.members.id
                               AND redmine.member_roles.role_id=redmine.roles.id
                               AND redmine.members.user_id=redmine.users.id
                               AND redmine.members.project_id=redmine.projects.id
                               AND redmine.projects.name=gitorious.repositories.name
                               AND redmine.users.type='User'
                               AND redmine.users.mail=gitorious.users.email
                               AND redmine.roles.name IN ('Инициатор','Менеджер','Major','Manager')
                               AND gitorious.repositories.user_id=gitorious.users.id;
                        " | grep -v tables_col|xargs|sed "s/ /\n/g"|tail -n+3`

# add repositories paths to chiliproject.repositories
chili_project_id=
gitorious_path=
let n=0
for v in $CHILI_ID_GITORIOUS_REPO; do
	let idx=n/2
	case $((n%2)) in
	0) chili_project_id=$v ;;
	1) gitorious_path=$GITORIOUS_REPOS_PATH/$v 
		echo "insert $chili_project_id: $gitorious_path"
		mysql -h$CHILI_MYSQL_HOSTNAME -u $CHILI_MYSQL_USER -e "INSERT INTO $CHILI_MYSQL_DBNAME.repositories(project_id,
		                                                                                                    url,
		                                                                                                    root_url,
		                                                                                                    type,
		                                                                                                    path_encoding,
		                                                                                                    extra_info)
		                                                       VALUES('$chili_project_id',
		                                                              '$gitorious_path',
		                                                              '$gitorious_path',
		                                                              'Git',
		                                                              '',
		                                                              '')"
	;;
	esac
	let n++
done
