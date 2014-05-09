#!/bin/bash

# load config files
if [ -f /etc/chiliproject_doxygen ]; then
	source /etc/chiliproject_doxygen
elif [ -f ~/etc/chiliproject_doxygen ]; then
	source ~/etc/chiliproject_doxygen
else
	echo "Config file not found ;-("
	exit -1
fi

# table
project_id=
type=
root_url=
#id= # the same as project_id
identifier=

# UMASK
umask 0002

# read $MYSQL_DBNAME.repositories to table
MYSQL_RESULT=`mysql -h127.0.0.1 -u $MYSQL_USER -e "SELECT repositories.project_id, repositories.type, repositories.root_url
    FROM $MYSQL_DBNAME.repositories, $MYSQL_DBNAME.enabled_modules
    WHERE $MYSQL_DBNAME.repositories.project_id=$MYSQL_DBNAME.enabled_modules.project_id
    AND $MYSQL_DBNAME.enabled_modules.name='redmine_embedded'" | grep -v tables_col|xargs|sed "s/ /\n/g"|tail -n+4`
let n=0
for v in $MYSQL_RESULT; do
	let idx=n/3
	case $((n%3)) in
	0) project_id[$idx]=$v;;
	1) type[$idx]=$v;;
	2) root_url[$idx]=$v;;
	esac
	let n++
done;
let n/=3

# read $MYSQL_DBNAME.projects to table
MYSQL_RESULT=`mysql -h127.0.0.1 -u $MYSQL_USER -e "SELECT projects.id, projects.identifier
    FROM $MYSQL_DBNAME.projects, $MYSQL_DBNAME.enabled_modules
    WHERE $MYSQL_DBNAME.projects.id=$MYSQL_DBNAME.enabled_modules.project_id
    AND $MYSQL_DBNAME.enabled_modules.name='redmine_embedded'" | grep -v tables_col|xargs|sed "s/ /\n/g"|tail -n+3`
last_idx=0
let i=0
for v in $MYSQL_RESULT; do
	case $((i%2)) in
	0) last_idx=$v
	;;
	1) for j in `seq 0 $((n-1))`; do
		if [ "$last_idx" == "${project_id[$j]}" ]; then
			identifier[$j]=$v
			break
		fi
	   done
	;;
	esac
	let i++
done

# remove old documentation
cd $DOC_PATH
[ $? != 0 ] && echo "cd $DOC_PATH failed" && rm -rf $TMP_PATH && exit -1
for d in *; do
	let found=false
	for i in `seq 0 $((n-1))`; do
		if [[ "${identifier[$i]}" == "$d" ]]; then
			found=true
			break
		fi
	done
	[ $found = 0 ] && rm -rf $d
done

# generate documentation
mkdir $TMP_PATH && cd $TMP_PATH
[ $? != 0 ] && echo "mkdir $TMP_PATH && cd $TMP_PATH failed" && rm -rf $TMP_PATH && exit -1
for i in `seq 0 $((n-1))`; do
	cd $TMP_PATH

	# Checkout last tags from repos. If no tags exist then go to next cycle iteration.
	LAST_TAG=""
	case ${type[$i]} in
	Mercurial|Repository::Mercurial)
		LAST_TAG=`hg tags --color never --noninteractive --quiet -R ${root_url[i]} 2>/dev/null \
		          | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+' | sort -Vr |  head -n1`
	;;
	Git|Repository::Git)
		cd ${root_url[$i]}
		[ $? != 0 ] && echo "cd ${root_url[$i]} failed" && continue
		LAST_TAG=`git tag | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+' | sort -Vr | head -n1`
		cd $TMP_PATH
	;;
	esac

	# Continue if no tags found
	[ "" == "$LAST_TAG" ] && echo "No tags found for project ${root_url[$i]}" &&  continue

	# If documentation exists for $LAST_TAG then continue
	[ "`cat $DOC_PATH/${identifier[$i]}/tag 2>/dev/null`" == "$LAST_TAG" ] \
	&& echo "Documentation alredy exists for ${identifier[$i]}" \
	&& cd $TMP_PATH && continue


	# Lock dir by creating tag file
	mkdir -p $DOC_PATH/${identifier[$i]} 2>/dev/null
	echo $LAST_TAG >$DOC_PATH/${identifier[$i]}/tag
	[ $? != 0 ] && echo "echo $LAST_TAG >$DOC_PATH/${identifier[$i]}/tag failed" && rm -rf $TMP_PATH && rm -f $DOC_PATH/${identifier[$i]}/tag && exit -1

	# GENERATING DOCUMENTATION
	echo "Generating documentation for ${root_url[$i]}"

	# Clone and Checkout
	case ${type[$i]} in
	Mercurial|Repository::Mercurial)
		repo_dir_name=${root_url[i]%/}
		repo_dir_name=${repo_dir_name##*/}
		hg clone ${root_url[i]} $TMP_PATH/$repo_dir_name && cd $TMP_PATH/$repo_dir_name
		[ $? != 0 ] && echo "hg clone ${root_url[i]} $TMP_PATH/$repo_dir_name && cd $TMP_PATH/$repo_dir_name failed" && rm -rf $TMP_PATH && rm -f $DOC_PATH/${identifier[$i]}/tag && exit -1
		hg up -C $LAST_TAG
	;;
	Git|Repository::Git)
		repo_dir_name=${identifier[$i]}
		git clone ${root_url[i]} $TMP_PATH/$repo_dir_name && cd $TMP_PATH/$repo_dir_name
		[ $? != 0 ] && echo "git clone ${root_url[i]} $TMP_PATH/$repo_dir_name && cd $TMP_PATH/$repo_dir_name failed" && rm -rf $TMP_PATH && rm -f $DOC_PATH/${identifier[$i]}/tag && exit -1
		git checkout $LAST_TAG
	;;
	esac

	# Converting Files to UTF-8 encoding
	find $TMP_PATH/$repo_dir_name \( ! -regex '.*/\..*' \) -type f -exec detect_encoding_and_convert.sh utf-8 '{}' \;
	
	# Generate doxygen documentation
	doxygen -g doxygen.conf
	# Get full project name
	PROJECT_NAME=`mysql -h127.0.0.1 -u $MYSQL_USER --default-character-set=utf8 -e "SELECT name FROM $MYSQL_DBNAME.projects WHERE id=${project_id[$i]}" | grep -v tables_col|xargs| sed "s/ /\n/g"|tail -n+2`

	sed "
	s~^PROJECT_NAME.*$~PROJECT_NAME = $PROJECT_NAME-$LAST_TAG~;
	s~^OUTPUT_LANGUAGE.*$~OUTPUT_LANGUAGE = English~;
	s~^BUILTIN_STL_SUPPORT.*$~BUILTIN_STL_SUPPORT = YES~;
	s~^EXTRACT_ALL.*$~EXTRACT_ALL = YES~;
	s~^EXTRACT_PRIVATE.*$~EXTRACT_PRIVATE = YES~;
	s~^EXTRACT_STATIC.*$~EXTRACT_STATIC = YES~;
	s~^EXTRACT_LOCAL_METHODS.*$~EXTRACT_LOCAL_METHODS = YES~;
	s~^EXTRACT_ANON_NSPACES.*$~EXTRACT_ANON_NSPACES = YES~;
	s~^FORCE_LOCAL_INCLUDES.*$~FORCE_LOCAL_INCLUDES = YES~;
	s~^SHOW_DIRECTORIES.*$~SHOW_DIRECTORIES = YES~;
	s~^RECURSIVE.*$~RECURSIVE = YES~;
	s~^SOURCE_BROWSER.*$~SOURCE_BROWSER = YES~;
	s~^VERBATIM_HEADERS.*$~VERBATIM_HEADERS = NO~;
	s~^REFERENCED_BY_RELATION.*$~REFERENCED_BY_RELATION = YES~;
	s~^REFERENCED_RELATION.*$~REFERENCED_RELATION = YES~;
	s~^GENERATE_LATEX.*$~GENERATE_LATEX = YES~;
	s~^HAVE_DOT.*$~HAVE_DOT = YES~;
	s~^UML_LOOK.*$~UML_LOOK = YES~;
	s~^TEMPLATE_RELATIONS.*$~TEMPLATE_RELATIONS = YES~;
	s~^CALL_GRAPH.*$~CALL_GRAPH = YES~;
	s~^CALLER_GRAPH.*$~CALLER_GRAPH = YES~;
	s~^EXCLUDE_PATTERNS.*$~EXCLUDE_PATTERNS = .hg .git~;
	s~^HTML_FOOTER.*$~HTML_FOOTER = footer.html~;
	s~^EXTRA_PACKAGES.*$~EXTRA_PACKAGES = babel~;
	" -i doxygen.conf

	# project name and version in the footer
	echo "<hr /><a href=\"$repo_dir_name-$LAST_TAG.pdf\">$repo_dir_name-$LAST_TAG.pdf</a>" > footer.html

	# run doxygen generator
	doxygen doxygen.conf

	# README in title page
	README="`find -maxdepth 1 -type f -iname 'readme*' | head -n1`"
	if [ -f "$README" ]; then
		sed -i 's~http\(\|s\)\(://[^ \n\t]*\)~<a href="http\1\2">http\1\2</a>~g' README
		sed -i 's~$~<br>~' "$README"
		sed -i "/<div class=\"contents\">/r $README" html/index.html
	fi

	# Copy html to $DOC_PATH
	mkdir -p $DOC_PATH/${identifier[$i]}
	[ $? != 0 ] && echo "mkdir -p $DOC_PATH/${identifier[$i]} failed" && rm -rf $TMP_PATH && rm -f $DOC_PATH/${identifier[$i]}/tag && exit -1
	rm -rf $DOC_PATH/${identifier[$i]}/html
	cp -r html $DOC_PATH/${identifier[$i]}
	sed 's~\<pdflatex\>~pdflatex -interaction batchmode~g' -i latex/Makefile
	sed 's~\\usepackage{babel}~\\usepackage[russian]{babel}~' -i latex/refman.tex
	make -C latex -f Makefile
	cp -f latex/refman.pdf $DOC_PATH/${identifier[$i]}/html/$repo_dir_name-$LAST_TAG.pdf

	# remove temp dir
	cd $TMP_PATH
	rm -rf $TMP_PATH/*
done

# remove $TMP_PATH
rm -rf $TMP_PATH

