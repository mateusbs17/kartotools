#!/bin/sh

# SET ENVIRONMENT VARIABLES
source ../.env

# Set NPM tree depth of search
DEPTH=2
# Repo to be analysed
ROOT_REPO=$1
# global helper to store checked blocked repo
BLOCKED_REPOS=""

# Check if there is anymirror under WMF repos
checkMirror()
{
	local repo=$1 
	
	local gerritMirror="$(curl -s -X GET "https://gerrit.wikimedia.org/r/projects/?r=.*\/${repo}&n=1" | sed "1 d" | jq ".[keys[] | select(contains(\"${repo}\"))].web_links[0].url" &> /dev/null)"
	if [ "$gerritMirror" = "" ]; then
		# If gerrit Mirror doesn't exists, search for mirror in Github
		local githubMWMirror="$(curl -s -H "$GITHUB_HEADER" -X GET "https://api.github.com/repos/wikimedia/${repo}" | jq '.["html_url"]' &> /dev/null)"
		# Check if github mirror exists
		if [ "$githubMWMirror" = "null" ]; then
			# Mirror doesn't exist
			echo "No"
		else    
			# Github Mirror exists
		    echo $githubMWMirror
		fi
	else
		# Gerrit Mirror exists
	    echo $gerritMirror
	fi
}

# Check if the project is a Top Level, Component dependency or 3rd party dependency
checkType()
{
	local repo=$1 
	local owner=$2
	# top-level
	local topLevelString="|kartotherian|kartographer|tilerator|osm-bright.tm2|osm-bright.tm2source|meddo|brighmed|"
	# dependency that is in karthotherian orgs	
	local componentLevelString="|snapshot|babel|jobprocessor|cassandra|core|module-loader|tilelive-tmsource|quadtile-index|server|maki|eslint-config-kartotherian|tilelive-vector|language-scripts|overzoom|substantial|err|tilelive-promise|geoshapes|layermixer|autogen|input-validator|postgres|demultiplexer|elasticsearch|editor|tilelive-http|abaculus|tilelive|htcp-purge|load-tester|mapdata|1"
	# string to check if the owner is Kartotherian or Wikimedia
	local ownerLevelString="|kartotherian|wikimedia|"
	if echo $topLevelString | grep -Eq ".*\|${repo}\|.*";
	then
	   	echo "Top level project"
	else if echo $componentLevelString | grep -Eq ".*\|${repo}\|.*";
		then
		  	echo "Kartotherian dependency"
		else if echo $ownerLevelString | grep -Eq ".*\|${owner}\|.*";
			then
				# Dependency not in Kartotherian namespace but owned by WMF
			 	echo "WMF dependency"
			else
				echo "3rd party dependency"
			fi
		fi
	fi
}

# Collect dependencies raw info and save it for filtering
repositoryRawInfo()
{
	local repo=$1
	local parent=$2
	local version=$4

	# log
	echo "repositoryRawInfo: repo ${repo} from parent ${parent}"

	# Start counter and init csv raw file if it's the first interaction
	if [ "$parent" = '' ]; then
		echo "" > "${CSV_PATH}/${ROOT_REPO}_raw_repo_info.csv"
		local count=0
	else 
		local count=$3
	fi

	# Repository NPM name
	local name=$(npm view $repo name)
	local latestVersion=$(npm view $repo version)
	# Who uses it?
	if [ "$count" -eq 0 ]; then
		# If is the first interation get repo name as root
		local whoUses="${name}"
	else
		# Get recursively each parent of the repo
		local whoUses="${parent}"
	fi

	# remove namespace from name to use it for getting github api info
	name="$(echo $name | sed "s/.*\/\(.*\)/\1/")"

	echo "$repo;$name;$version;$latestVersion;$whoUses" >> "${CSV_PATH}/${ROOT_REPO}_raw_repo_info.csv"

	# TODO: Get the version of the library

	# recursevely get dependecies info 
	if [ "$count" -lt "$DEPTH" ]; then
		raw_depedencies_info="$(npm view $repo dependencies)"
		# get all dependecies with version as XARGS
		
		if [ ${count} -eq 0 ]; then
			# Kartotherian is outdated at npmjs and need to have its package.json file parsed at the first round
			cd $repo
			XARGS_DEPS=$(npm ls --json --depth=0 | grep "from" | sed "/ERR\!/d; s/\"from\"://; s/\s//g; s/\(.*\),$/\1/g; s/\"//g; s/@\([*\^~0-9].*$\)/:\1/;"| xargs)
		else 
			XARGS_DEPS=$(echo "${raw_depedencies_info}" | sed "1 d; $ d; s/\s//g; s/'//g; s/{//g" | sed "s/\(.*\),$/\1/g" | xargs)
			# JSON_DEPS=$(npm view $repo dependencies | sed "1 d; $ d; s/\s//g; s/'//g; s/{//g" | sed "s/\(.*\):.*/\1/g" | sed "s/\(.*\)/\"\1\"/g" | sed '$!s/$/,/' | sed "1 s/^/[/; $ s/$/]/")
		fi
		# Increase counter to know where 
		count=$((count+1))
		for dep in $XARGS_DEPS; do
			# Recursion fun
			dependency=$(echo "${dep}" | sed "s/\(.*\):.*$/\1/g")
			version=$(echo "${dep}" | sed "s/.*[:~^]\(.*$\)/\1/g")
			repositoryRawInfo $dependency "${parent}/${repo}" $count $version
		done
	fi
}

# Remove duplication of repositories and aggregate 'who uses' info
filterRepositoryRawInfo()
{
	# log
	echo "filterRepositoryRawInfo"

	# Read raw file
	# Find for repos with names alike (group by)
	# Count number of repos grouped
	# Extract and merge information into one line
	awk -F "\"*;\"*" '{
	if(NR!=1){
		count_repo[$2]=count_repo[$2] + 1
		repo[$2]=$1
		version[$2]=$3
		latestVersion[$2]=$4
		whoUses[$2]=$5", "whoUses[$2]
	} else 
      	print $0
    } END {
		n = asorti(whoUses, repo_name);
		for (n in repo_name) {
			print count_repo[repo_name[n]]";"repo[repo_name[n]]";"repo_name[n]";"version[repo_name[n]]";"latestVersion[repo_name[n]]";"whoUses[repo_name[n]]
		}
    }' "${CSV_PATH}/${ROOT_REPO}_raw_repo_info.csv" | sed "s/\(.*\), $/\1/" > "${CSV_PATH}/${ROOT_REPO}_filtered_repo_info.csv"
}

# Get the rest of the info for non-duplicated repository info
completeRepositoryInfo()
{
	local noc=$1
	local repo=$2
	local name=$3
	local version=$4
	local latestVersion=$5
	local whoUses="$(echo $6 | sed "s/|/ /g")"
	
	# log
	echo "completeRepositoryInfo: ${repo} used by ${whoUses}"

	# Where is it hosted? && Link && Who owns the repo && Repo's Github Name
	local link=$(npm view $repo repository.url | sed "s/^git+//g" | sed "s/git:\|ssh:/https:/g" | sed "s/\.git//g" | sed "s/git@//g" | sed "s/^\(github.*\):/https:\/\/\1\//")
	local whereHosted=$(echo $link | sed "s/http.*\/\(.*\)\/\(.*\)\/\(.*\)/\1/g")

	if echo "$whereHosted" | grep -Eq ".*gerrit.*"; 
	then
		local whoOwns="wikimedia"
	else 
		local whoOwns=$(echo $link | sed "s/http.*\/\(.*\)\/\(.*\)\/\(.*\)/\2/g")
	fi

	local githubName=$(echo $link | sed "s/http.*\/\(.*\)\/\(.*\)\/\(.*\)/\3/g")

	local githubUrl="https://api.github.com/repos/${whoOwns}/${githubName}"
	local githubInfo="$(curl -s -H "$GITHUB_HEADER" -X GET $githubUrl)"
	local message="$(echo $githubInfo | jq '.["message"]')"
	case "$message" in
		null)
			githubStatus="OK"
			;;
		'"Moved Permanently"')
			githubUrl=$(echo $githubInfo | jq '.["url"]' | sed "s/\"//g")
			githubStatus="${message}"
			githubInfo="$(curl -s -H "$GITHUB_HEADER" -X GET $githubUrl)"
			;;
		*) 
			githubUrl="https://api.github.com/repos/${whoOwns}/${name}"
			githubStatus="${message}"
			githubInfo="$(curl -s -H "$GITHUB_HEADER" -X GET $githubUrl)"
			;;
	esac

	local communityHealthPercentage="$(curl -s -H "$GITHUB_HEADER" -H "Accept: application/vnd.github.black-panther-preview+json" -X GET "${githubUrl}/community/profile" | jq '.["health_percentage"]' | sed "s/null/Not Available/")"
	local lastUpdate="$(echo $githubInfo | jq '.["updated_at"]' | sed "s/\(.*\)T.*Z/\1/; s/null/Not Available/")"
	local language="$(echo $githubInfo | jq '.["language"]' | sed "s/null/Not Available/")"
	local openIssuesCount="$(echo $githubInfo | jq '.["open_issues_count"]' | sed "s/null/Not Available/")"

	# Who owns the package/library publishing?
	local whoPublishes="$(npm owner ls $repo | xargs)"
	# We have a WMF mirror? 
	local mirror="$(checkMirror "$(echo $githubName | sed "s/.*\///")")"
	# Check the type of the repo
	local type="$(checkType "$(echo $githubName | sed "s/.*\///")" "$(echo $whoOwns)")"

	# Append everything on CSV file
	# 
	# $noc => Number of calls
	# $type => Type of the repository: Top level application, WMF dependency, Kartotherian dependency or 3rd party application
	# $name => Name of the repository
	# $version => Name of the repository
	# $latestVersion => Name of the repository
	# $whoUses => Dependency or project that uses the repository
	# $whoOwns => Namespace of the person/org that owns the repo
	# $whoPublishes => Contact of the persons that publishes the repo on NPM
	# $whereHosted => Site where the repository is hosted
	# $mirror => Indication if mirror exists and its URL
	# $link => Repository URL page
	# $lastUpdate => Last update on the repository
	# $language => Programming language of the project
	# $openIssuesCount => Number of open issues from Github API
	# $githubStatus => Response from Github API on fisrt fetch
	# $communityHealthPercentage => Github community overall health score
	echo "$noc;$type;$name;$version;$latestVersion;$whoUses;$whoOwns;$whoPublishes;$whereHosted;$mirror;$link;$lastUpdate;$language;$openIssuesCount;$githubStatus;$communityHealthPercentage" >> "${CSV_PATH}/${ROOT_REPO}_maps_repos.csv"
}

# Read filtered data and call completeRepositoryInfo to finish the info collection
postFilter()
{
	local count=0

	while IFS=";" read noc repo name version latestVersion whoUses
	do
		if [ "${DEBUG_LINE}" = "true" ]; then
			count=$((count+1));		
		fi
		if [ $count -eq 0 ] || { [ $count -ne 0 ] && [ $count -eq $LINE ]; }; then
			whoUses=$(echo $whoUses | sed "s/, /,|/g") # Hack to pass string without space to prevent truncation
			completeRepositoryInfo $noc $repo $name $version $latestVersion "${whoUses}"
		fi
	done < "${CSV_PATH}/${ROOT_REPO}_filtered_repo_info.csv"
}

# Post-process the repository CSV and look for blocked dependencies
getParents()
{
	local repo=$1

	local count=0

	local result=""

	while IFS=";" read noc type name version latestVersion whoUses whoOwns whoPublishes whereHosted mirror link lastUpdate language openIssuesCount githubStatus communityHealthPercentage
	do
		if [ "${DEBUG_LINE}" = "true" ]; then
			count=$((count+1));		
		fi
		if [ $count -eq 0 ] || { [ $count -ne 0 ] && [ $count -eq $LINE ]; }; then
			
			# Has blocked dependencies
			if [ "$repo" = "$name" ] || echo $whoUses | grep -Eq ".*$repo($|,)"; then
				echo $name >> "${CSV_PATH}/${ROOT_REPO}_blocked"
				# if echo $BLOCKED_REPOS | grep -Eqv ".*\|${name}\|.*"; then
				# fi
				if [ ! -z "$whoUses" ]; then
					result="$result $whoUses"
				fi
			fi
		fi
	done < "${CSV_PATH}/${ROOT_REPO}_maps_repos.csv"
	echo $(echo $result | grep -Po "\/([a-zA-Z-]+)(,|$)" | sed "s/[,\/]//g")
}

recursevelyCheckBlockedDependency()
{
	local repo=$1
	# TODO: Add new column
	for parent in $(getParents $repo)
	do
		if [ ! "$parent" = "$ROOT_REPO" ]; then
			echo $parent
			if grep -Fxq "$parent" "${CSV_PATH}/${ROOT_REPO}_blocked_aux"; then
				:
			else
				echo $parent >> "${CSV_PATH}/${ROOT_REPO}_blocked_aux"
					recursevelyCheckBlockedDependency $parent
			fi
		fi
	done
	
}

postProcessBlocked()
{
	echo "Number of calls;Type;Repository;Version;Latest version;Who uses it?;Who owns the repo?;Who owns the package/library publishing?;Where is it hosted?;We have a WMF mirror?;Link;Last update;Language;Open issues count;Github Status;Community Health Percentage; Is Blocked" > "${CSV_PATH}/${ROOT_REPO}_maps_repos_final.csv"
	local isBlocked="false"
	while IFS=";" read noc type name version latestVersion whoUses whoOwns whoPublishes whereHosted mirror link lastUpdate language openIssuesCount githubStatus communityHealthPercentage
	do
		isBlocked="false"
		if grep -Fxq "$name" "${CSV_PATH}/${ROOT_REPO}_blocked"; then
			isBlocked="true"
		fi
		echo "$noc;$type;$name;$version;$latestVersion;$whoUses;$whoOwns;$whoPublishes;$whereHosted;$mirror;$link;$lastUpdate;$language;$openIssuesCount;$githubStatus;$communityHealthPercentage;$isBlocked" >> "${CSV_PATH}/${ROOT_REPO}_maps_repos_final.csv"
	done < "${CSV_PATH}/${ROOT_REPO}_maps_repos.csv"
}

# Get options and execute desired function, mainly for development and to speed up data analysis
case $2 in
	raw )
		repositoryRawInfo $ROOT_REPO
		;;
	filter )
		filterRepositoryRawInfo
		;;
	postfilter )
		# Init CSV file
		echo "Number of calls;Type;Repository;Version;Latest version;Who uses it?;Who owns the repo?;Who owns the package/library publishing?;Where is it hosted?;We have a WMF mirror?;Link;Last update;Language;Open issues count;Github Status;Community Health Percentage" > "${CSV_PATH}/${ROOT_REPO}_maps_repos.csv"
		postFilter
		;;
	checkdep )
		echo "" > "${CSV_PATH}/${ROOT_REPO}_blocked"
		echo "mapnik" >"${CSV_PATH}/${ROOT_REPO}_blocked_aux"
		recursevelyCheckBlockedDependency mapnik
		postProcessBlocked
		;;
	* )
		# Init CSV file
		echo "Number of calls;Type;Repository;Version;Latest version;Who uses it?;Who owns the repo?;Who owns the package/library publishing?;Where is it hosted?;We have a WMF mirror?;Link;Last update;Language;Open issues count;Github Status;Community Health Percentage" > "${CSV_PATH}/${ROOT_REPO}_maps_repos.csv"
		repositoryRawInfo $ROOT_REPO
		filterRepositoryRawInfo
		postFilter
		;;
esac

exit