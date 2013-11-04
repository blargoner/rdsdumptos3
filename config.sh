#!/bin/bash

#
# RDS MySQL dump to S3
# Copyright (c) 2013 John Peloquin. All rights reserved.
#
# Configuration.
#

#
# Client IP address.
#
# Required only for RDS ingress (see below). If blank, the tool will attempt to
# automatically determine the IP address if required. 
ip=

#
# Gateway mode.
#
# If true, indicates that there is an internet gateway (NAT) between client and
# server, hence an external service is required to determine client WAN IP.
#
gateway=false

#
# AWS access key. Required.
#
aws_access_key_id=

#
# AWS secret key. Required.
#
aws_secret_access_key=

#
# RDS region. Required.
#
rds_region=

#
# RDS DB instance identifier. Required.
#
rds_db_instance_identifier=

#
# RDS DB security group name.
#
# Required only for RDS ingress (see below). If blank, the tool will attempt to
# automatically determine the security group name if required.
#
rds_db_security_group_name=

#
# RDS DB security group ingress.
#
# If true, the tool will authorize ingress from the client IP address to the RDS
# DB security group prior to dumping, and revoke after.
#
rds_ingress=false

#
# S3 bucket. Required.
#
s3_bucket=

#
# S3 object key prefix.
#
s3_prefix=

#
# MySQL dump command.
#
# Edit command to customize options.
#
# Variables:
#
# rds_db_endpoint_address   - RDS DB instance address (hostname)
# rds_db_endpoint_port      - RDS DB instance port
#
function mysql_dump () {
    mysqldump \
        --no-defaults \
        --skip-add-drop-table \
        --skip-add-locks \
        --skip-comments \
        --compress \
        --skip-disable-keys \
        --skip-lock-tables \
        --max-allowed-packet=10M \
        --order-by-primary \
        --no-create-db \
        --single-transaction \
        --skip-triggers \
        --skip-tz-utc \
        --host="${rds_db_endpoint_address}" \
        --port="${rds_db_endpoint_port}" \
        --user=username \
        --password \
        --ssl-ca=/path/to/mysql-ssl-ca-cert.pem \
        --all-databases
}

#
# S3 put command.
#
# Edit command to customize options.
#
# Parameters:
#   $1 - dump filename
#   $2 - dump timestamp
#
function s3_put () {
    local key="${s3_prefix}${rds_db_instance_identifier}-$2.sql.gz"
    aws s3api put-object \
        --bucket "${s3_bucket}" \
        --key "${key}" \
        --body "$1" \
        --server-side-encryption 'AES256' >/dev/null
}

