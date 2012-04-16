#!/bin/bash

# load config files
[ -f /etc/rhodecode_chiliproject ] && source /etc/rhodecode_chiliproject
[ -f ~/etc/rhodecode_chiliproject ] && source ~/etc/rhodecode_chiliproject

# === REMOVE ALL BROKEN REPOSITORY LINKS IN CHILIPROJECT MYSQL DATABASE ===
ALL_MYSQL_REPOS=`mysql -h$CHILI_MYSQL_HOSTNAME -u $CHILI_MYSQL_USER -e "SELECT url,root_url,id FROM $CHILI_MYSQL_DBNAME.repositories WHERE type='Mercurial' OR type='Repository::Mercurial'" | grep -v tables_col|xargs|sed "s/ /\n/g"|tail -n+4`
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

# === GET DATA FROM RHODECODE SQLITE BASE ===
rh_repos_path=`sqlite3 $RHODECODE_SQLITE_PATH "select ui_value FROM rhodecode_ui where ui_section='paths'"`

SQLITE_RESULTS=`sqlite3 $RHODECODE_SQLITE_PATH "SELECT repo_name,repo_type,users.username,users_groups.users_group_name
                                      FROM repositories,users,users_groups,users_groups_members
				      WHERE repositories.user_id=users.user_id
				      AND users.user_id=users_groups_members.user_id
				      AND users_groups.users_group_id=users_groups_members.users_group_id;"`

# initializing repos arrays and count them
repos_names=
repos_paths=
repos_types=
repos_users=
repos_groups=

let nrepos=0
for r in $SQLITE_RESULTS; do
	repos_paths[$nrepos]=$rh_repos_path/${r%|*|*|*}
	tmp=${repos_paths[$nrepos]%/}; repos_names[$nrepos]=${tmp##*/}
	tmp=${r%|*|*}; repos_types[$nrepos]=${tmp#*|}
	case ${repos_types[$nrepos]} in
	hg) repos_types[$nrepos]='Mercurial';;
	git) repos_types[$nrepos]='Git';;
	esac
	tmp=${r%|*}; repos_users[$nrepos]=${tmp#*|*|}
	repos_groups[$nrepos]=${r#*|*|*|}
	let nrepos++
done

# === FOR ALL REPOS FROM RHODECODE DATABASE===
for i in `seq 0 $((nrepos-1))`; do
	# === GET DATA FROM CHILIPROJECT MYSQL BASE ===
	ALREADY_EXIST=`mysql -h$CHILI_MYSQL_HOSTNAME -u $CHILI_MYSQL_USER -e "SELECT id
	                                                FROM $CHILI_MYSQL_DBNAME.repositories
	                                                WHERE url='${repos_paths[$i]}'
							OR root_url='${repos_paths[$i]}'" \
	                                                | grep -v tables_col|xargs|sed "s/ /\n/g"|tail -n+2`
	[ "$ALREADY_EXIST" != "" ] && continue

	USERID=`mysql -h$CHILI_MYSQL_HOSTNAME -u $CHILI_MYSQL_USER -e "SELECT id
                                                 FROM $CHILI_MYSQL_DBNAME.users,$CHILI_MYSQL_DBNAME.groups_users
                                                 WHERE users.id=groups_users.user_id
						 AND users.status='1'
						 AND users.login='${repos_users[$i]}'
						 AND users.type='User'
						 AND groups_users.group_id=(SELECT id
						                            FROM $CHILI_MYSQL_DBNAME.users
									    WHERE users.type='Group'
									    AND users.lastname='${repos_groups[$i]}'
									    AND users.status='1')" \
	                                         | grep -v tables_col|xargs|sed "s/ /\n/g"|tail -n+2`
	[ "$USERID" == "" ] && continue

	PROJECTID=`mysql -h$CHILI_MYSQL_HOSTNAME -u $CHILI_MYSQL_USER -e "SELECT id FROM $CHILI_MYSQL_DBNAME.projects
								WHERE (name='${repos_names[$i]}'
								OR identifier='${repos_names[$i]}')
								AND status='1'" \
								| grep -v tables_col|xargs|sed "s/ /\n/g"|tail -n+2`
	[ "$PROJECTID" == "" ] && continue

	roles_mysql_string=`echo $CHILI_REQUIRED_ROLES | sed "s~\>~'~g ; s~\<~OR roles.name='~g ; s~^OR ~~"`
	ROLES=`mysql --default-character-set=utf8 -h$CHILI_MYSQL_HOSTNAME -u $CHILI_MYSQL_USER -e "SELECT roles.name
	                                        FROM $CHILI_MYSQL_DBNAME.roles,$CHILI_MYSQL_DBNAME.member_roles,$CHILI_MYSQL_DBNAME.members
						WHERE roles.id=member_roles.role_id
						AND member_roles.member_id=members.id
						AND members.user_id='$USERID'
						AND members.project_id='$PROJECTID'
						AND ($roles_mysql_string)" \
					        | grep -v tables_col|xargs|sed "s/ /\n/g"|tail -n+2`

	[ "$ROLES" == "" ] && continue

	# === ATTACH RHODECODE REPOSITORY TO CHILIPROJECT ===
	# DEBUG
	echo "insert $PROJECTID,${repos_paths[$i]},${repos_types[$i]}"

	mysql -h$CHILI_MYSQL_HOSTNAME -u $CHILI_MYSQL_USER -e "INSERT INTO $CHILI_MYSQL_DBNAME.repositories(project_id,
	                                                          url,
								  root_url,
								  type,
								  path_encoding,
								  extra_info)
						VALUES('$PROJECTID',
						       '${repos_paths[$i]}',
						       '${repos_paths[$i]}',
						       '${repos_types[$i]}',
						       '',
						       '')"
done

