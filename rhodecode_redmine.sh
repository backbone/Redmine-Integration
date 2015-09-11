#!/bin/bash

# load config files
if [ -f /etc/rhodecode_redmine ]; then
	source /etc/rhodecode_redmine
elif [ -f ~/etc/rhodecode_redmine ]; then
	source ~/etc/rhodecode_redmine
else
	echo "Config file not found ;-("
	exit -1
fi

# === REMOVE ALL BROKEN REPOSITORY LINKS IN REDMINE MYSQL DATABASE ===
ALL_MYSQL_REPOS=`mysql -h$REDMINE_MYSQL_HOSTNAME -u $REDMINE_MYSQL_USER -e "SELECT url,root_url,id
                                                                        FROM $REDMINE_MYSQL_DBNAME.repositories
                                                                        WHERE type='Mercurial'
                                                                              OR type='Repository::Mercurial'" \
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
        2) [ ! -d $current_url/.hg -a ! -d $current_root_url/.hg ] && repos_to_remove="$repos_to_remove,$v";;
        esac
        let n++
done;
repos_to_remove=${repos_to_remove#,}
[ "$repos_to_remove" != "" ] && mysql -h$REDMINE_MYSQL_HOSTNAME -u $REDMINE_MYSQL_USER -e "DELETE
                                                                                       FROM $REDMINE_MYSQL_DBNAME.repositories
                                                                                       WHERE id IN ($repos_to_remove)"

# === GET DATA FROM RHODECODE SQLITE BASE ===
rh_repos_path=`sqlite3 $RHODECODE_SQLITE_PATH "SELECT ui_value
                                               FROM rhodecode_ui
                                               WHERE ui_section='paths'"`

SQLITE_RESULTS=`sqlite3 $RHODECODE_SQLITE_PATH "SELECT repo_name,repo_type,users.email
                                                FROM repositories,users
                                                WHERE repositories.user_id=users.user_id;"`

# initializing repos arrays and count them
repos_names=
repos_paths=
repos_types=
repos_mails=

let nrepos=0
for r in $SQLITE_RESULTS; do
	repos_paths[$nrepos]=$rh_repos_path/${r%|*|*}
	tmp=${repos_paths[$nrepos]%/}; repos_names[$nrepos]=${tmp##*/}
	tmp=${r%|*}; repos_types[$nrepos]=${tmp#*|}
	case ${repos_types[$nrepos]} in
		hg) repos_types[$nrepos]='Repository::Mercurial';;
		git) repos_types[$nrepos]='Repository::Git';;
	esac
	repos_mails[$nrepos]=${r#*|*|}
	let nrepos++
done

# === FOR ALL REPOS FROM RHODECODE DATABASE===
for i in `seq 0 $((nrepos-1))`; do
	# === GET DATA FROM REDMINE MYSQL BASE ===
	USERID=`mysql -h$REDMINE_MYSQL_HOSTNAME -u $REDMINE_MYSQL_USER -e "SELECT id
	                                                               FROM $REDMINE_MYSQL_DBNAME.users,$REDMINE_MYSQL_DBNAME.email_addresses
	                                                               WHERE users.status='1'
	                                                                     AND email_addresses.address='${repos_mails[$i]}'
	                                                                     AND email_addresses.is_default='1'
	                                                                     AND users.id=email_addresses.user_id
	                                                                     AND users.type='User'" \
	                                                               | grep -v tables_col|xargs|sed "s/ /\n/g"|tail -n+2`
	[ "$USERID" == "" ] && continue

	PROJECTID=`mysql -h$REDMINE_MYSQL_HOSTNAME -u $REDMINE_MYSQL_USER -e "SELECT DISTINCT id FROM $REDMINE_MYSQL_DBNAME.projects
	                                                                  WHERE name='${repos_names[$i]}'
	                                                                        AND status='1'" \
	                                                                  | grep -v tables_col|xargs|sed "s/ /\n/g"|tail -n+2`
	[ "$PROJECTID" == "" ] && continue

	REMOVE_ID=`mysql -h$REDMINE_MYSQL_HOSTNAME -u $REDMINE_MYSQL_USER -e "SELECT repositories.id
	                                                                  FROM $REDMINE_MYSQL_DBNAME.repositories,$REDMINE_MYSQL_DBNAME.projects
	                                                                  WHERE (repositories.url='${repos_paths[$i]}'
	                                                                        OR repositories.root_url='${repos_paths[$i]}')
	                                                                        AND repositories.project_id=projects.id
	                                                                        AND projects.name <> '${repos_names[$i]}'" \
	                                                                  | grep -v tables_col|xargs|sed "s/ /\n/g"|tail -n+2`

	[ "$REMOVE_ID" != "" ] && mysql -h$REDMINE_MYSQL_HOSTNAME -u $REDMINE_MYSQL_USER -e "DELETE
	                                                                                 FROM $REDMINE_MYSQL_DBNAME.repositories
	                                                                                 WHERE id = '$REMOVE_ID'"

	ALREADY_EXIST=`mysql -h$REDMINE_MYSQL_HOSTNAME -u $REDMINE_MYSQL_USER -e "SELECT id
	                                                                      FROM $REDMINE_MYSQL_DBNAME.repositories
	                                                                      WHERE project_id='$PROJECTID'
	                                                                            OR url='${repos_paths[$i]}'
	                                                                            OR root_url='${repos_paths[$i]}'" \
	                                                                      | grep -v tables_col|xargs|sed "s/ /\n/g"|tail -n+2`
	[ "$ALREADY_EXIST" != "" ] && continue

	roles_mysql_string=`echo $REDMINE_REQUIRED_ROLES | sed "s~\>~'~g ; s~\<~,'~g ; s~^,~~ ; s~ ~~g"`
	ROLES=`mysql --default-character-set=utf8 -h$REDMINE_MYSQL_HOSTNAME -u $REDMINE_MYSQL_USER -e "SELECT roles.name
	                                                                                           FROM $REDMINE_MYSQL_DBNAME.roles,
	                                                                                                $REDMINE_MYSQL_DBNAME.member_roles,
	                                                                                                $REDMINE_MYSQL_DBNAME.members
	                                                                                           WHERE roles.id=member_roles.role_id
	                                                                                                 AND member_roles.member_id=members.id
	                                                                                                 AND members.user_id='$USERID'
	                                                                                                 AND members.project_id='$PROJECTID'
	                                                                                                 AND roles.name IN ($roles_mysql_string)" \
	                                                                                           | grep -v tables_col|xargs|sed "s/ /\n/g"|tail -n+2`

	[ "$ROLES" == "" ] && continue

	# === ATTACH RHODECODE REPOSITORY TO REDMINE ===
	# DEBUG
	echo "insert $PROJECTID,${repos_paths[$i]},${repos_types[$i]}"

	mysql -h$REDMINE_MYSQL_HOSTNAME -u $REDMINE_MYSQL_USER -e "INSERT INTO $REDMINE_MYSQL_DBNAME.repositories(project_id,
	                                                                                                    url,
	                                                                                                    root_url,
	                                                                                                    type,
	                                                                                                    path_encoding,
	                                                                                                    is_default)
	                                                       VALUES('$PROJECTID',
	                                                              '${repos_paths[$i]}',
	                                                              '${repos_paths[$i]}',
	                                                              '${repos_types[$i]}',
	                                                              '',
	                                                              1)"
done
