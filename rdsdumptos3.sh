#!/bin/bash

#
# RDS MySQL dump to S3
# Copyright (c) 2013 John Peloquin. All rights reserved.
#
# Requirements:
#   - aws-cli (AWS command line tools)
#   - jq (JSON parser)
#   - mysqldump
#

#
# Loads config.
#
function get_config () {
    # load config
    source config.sh || return

    # check config
    if [[ -z "${aws_access_key_id}" || -z "${aws_secret_access_key}" ]]
    then
        echo 'Configure AWS credentials.' >&2
        return 1
    elif [[ -z "${rds_region}" || -z "${rds_db_instance_identifier}" ]]
    then
        echo 'Configure RDS.' >&2
        return 1
    elif [[ -z "${s3_bucket}" ]]
    then
        echo 'Configure S3.' >&2
        return 1
    fi

    # set global aws config
    export AWS_ACCESS_KEY_ID="${aws_access_key_id}"
    export AWS_SECRET_ACCESS_KEY="${aws_secret_access_key}"
}

#
# Gets client IP.
#
function get_ip () {
    if ! ${rds_ingress}
    then :
        # if not ingressing, do not need ip
    elif [[ "${ip}" ]]
    then
        # otherwise, if ip is configured, use it
        echo "Using IP address ${ip}."
    elif ! ${gateway}
    then
        # otherwise, if not behind a gateway, use first interface ip
        ip=`hostname -I | cut -d' ' -f1`
        echo "Using IP address ${ip}. (If incorrect, configure manually.)"
    else
        # otherwise, let me google that for you...
        echo 'Finding IP address...'
        ip=`curl 'http://www.bing.com/search?q=my+ip+address' 2>/dev/null | grep -Pom 1 '(\d{1,3}\.){3}\d{1,3}'`
        if [[ $? -ne 0 ]]
        then
            echo 'Unable to find IP address. Configure manually.' >&2
            return 1
        fi
        echo "Found IP address ${ip}. (If incorrect, configure manually.)"
    fi
    return 0
}

#
# Gets RDS DB instance details.
#
function get_rds_details () {
    local desc
    echo "Getting details of RDS DB instance ${rds_db_instance_identifier}..."
    desc=`aws rds describe-db-instances --region "${rds_region}" --db-instance-identifier "${rds_db_instance_identifier}"`
    if [[ $? -ne 0 ]]
    then
        echo 'Unable to get RDS DB instance details.' >&2
        return 1
    fi
    desc=`jq '.DBInstances[0]' <<< "${desc}"`
    if ${rds_ingress}
    then
        # if ingressing, get security group
        if [[ -z "${rds_db_security_group_name}" ]]
        then
            # if security group is not configured, use the first one
            rds_db_security_group_name=`jq -r '.DBSecurityGroups[0].DBSecurityGroupName' <<< "${desc}"`
        fi
        echo "Security group: ${rds_db_security_group_name}. (If incorrect, configure manually.)"
    fi
    rds_db_endpoint_address=`jq -r '.Endpoint.Address' <<< "${desc}"`
    rds_db_endpoint_port=`jq -r '.Endpoint.Port' <<< "${desc}"`
    echo "Address: ${rds_db_endpoint_address}."
    echo "Port: ${rds_db_endpoint_port}."
    return 0
}

#
# Authorizes ingress on RDS DB security group from client IP.
#
function auth_rds_ingress () {
    ${rds_ingress} || return 0
    local cidrip="${ip}/32"
    echo "Authorizing ingress on RDS DB security group ${rds_db_security_group_name} from ${cidrip}..."
    aws rds authorize-db-security-group-ingress \
        --region "${rds_region}" \
        --db-security-group-name "${rds_db_security_group_name}" \
        --cidrip "${cidrip}" >/dev/null
    if [[ $? -ne 0 ]]
    then
        echo 'Unable to authorize RDS ingress.' >&2
        return 1
    fi
    # poll for authorization
    local auth='false' desc
    while [[ "${auth}" != 'true' ]]
    do
        sleep 5
        desc=`aws rds describe-db-security-groups --region "${rds_region}" --db-security-group-name "${rds_db_security_group_name}"`
        if [[ $? -ne 0 ]]
        then
            echo 'Unable to get RDS DB security group details.' >&2
            revoke_rds_ingress
            return 1
        fi
        auth=`jq ".DBSecurityGroups[0].IPRanges | map(select(.CIDRIP == \"${cidrip}\" and .Status == \"authorized\")) | length != 0" <<< "${desc}"`
    done
    echo 'Authorized.'
    return 0
}

#
# Revokes ingress on RDS DB security group from client IP.
#
function revoke_rds_ingress () {
    ${rds_ingress} || return 0
    local cidrip="${ip}/32"
    echo "Revoking ingress on RDS DB security group ${rds_db_security_group_name} from ${cidrip}..."
    aws rds revoke-db-security-group-ingress \
        --region "${rds_region}" \
        --db-security-group-name "${rds_db_security_group_name}" \
        --cidrip "${cidrip}" >/dev/null
    if [[ $? -ne 0 ]]
    then
        echo 'Unable to revoke RDS ingress.' >&2
        return 1
    fi
    echo 'Revoked.'
    return 0
}

#
# Gets MySQL dump local temporary filename.
#
function get_dump_file () {
    mktemp --tmpdir 'rdsdumptos3.XXXXXXXXXX.sql.gz'
}

#
# Dumps MySQL data.
#
# Parameters:
#   $1 - filename
#
function dump_mysql () {
    echo "Dumping MySQL data..."
    mysql_dump | gzip -9 > "$1"
    if [[ ${PIPESTATUS[0]} -ne 0 || $? -ne 0 ]]
    then
        echo 'Unable to dump MySQL data.' >&2
        return 1
    fi
    echo "Dumped."
}

#
# Uploads file to S3.
#
# Parameters:
#   $1 - filename
#   $2 - timestamp
#
function upload_to_s3 () {
    echo "Uploading to S3..."
    s3_put "$1" "$2"
    if [[ $? -ne 0 ]]
    then
        echo 'Unable to upload to S3.' >&2
        return 1
    fi
    echo "Uploaded."
}

# get config
get_config || exit

# get ip
get_ip || exit

# get rds details
get_rds_details || exit

# authorize rds ingress
auth_rds_ingress || exit

# dump mysql
mysql_dump_file=`get_dump_file`
mysql_dump_ts=`date +%s`
dump_mysql "${mysql_dump_file}"
if [[ $? -ne 0 ]]
then
    rm "${mysql_dump_file}"
    revoke_rds_ingress
    exit 1
fi

# upload dump to s3
upload_to_s3 "${mysql_dump_file}" "${mysql_dump_ts}"
if [[ $? -ne 0 ]]
then
    rm "${mysql_dump_file}"
    revoke_rds_ingress
    exit 1
fi

# delete dump
rm "${mysql_dump_file}"

# revoke rds ingress
revoke_rds_ingress

echo 'Done.'

