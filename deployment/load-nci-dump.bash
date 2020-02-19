#!/usr/bin/env bash

set -eu
umask 0022

# NCI dates are in AEST
export TZ="Australia/Sydney"

# Remove any previous pgdump files before processing cubedash job
rm -rf /data/nci/*-datacube.pgdump

# Optional first argument is day to load (eg. "yesterday")
dump_id="$(date "-d${1:-today}" +%Y%m%d)"

export PGUSER="$2"
export PGHOST="$1"
export PGPORT=5432
bit_bucket_branch="eks-prod"

psql_args="-h ${PGHOST} -p ${PGPORT} -U ${PGUSER}"

dump_file="/data/nci/105-${dump_id}-datacube.pgdump"
app_dir="/var/www/dea-dashboard"

archive_dir="archive"
summary_dir="${archive_dir}/${dump_id}"
dbname="nci_${dump_id}"

log_file="${summary_dir}/restore-$(date +'%dT%H%M').log"
python=/opt/conda/bin/python

echo "======================="
echo "Loading dump: ${dump_id}"
echo "      dbname: ${dbname}"
echo "         app: ${app_dir}"
echo "        args: ${psql_args}"
echo "         log: ${app_dir}/${log_file}"
echo "======================="
echo " in 5, 4, 3..."
sleep 5

cd "${app_dir}"
mkdir -p "${summary_dir}"
exec > "${log_file}"
exec 2>&1

function log_info {
    printf '### %s\n' "$@"
}

function finish {
    log_info "Exiting $(date)"
}
trap finish EXIT

log_info "Starting restore $(date)"
# Print local lowercase variables into log
log_info "Vars:"
(set -o posix; set) | grep -e '^[a-z_]\+=' | sed 's/^/    /'

if psql -lqtA | grep -q "^$dbname|";

then
    log_info "DB exists"
else
    if [[ ! -e "${dump_file}" ]];
    then
        # Fetch new one
        log_info "Downloading backup from NCI. If there's no credentials, you'll have to do this manually and rerun:"
        # Our public key is whitelisted in lpgs to scp the latest backup (only)
        # '-p' to preserve time the backup was taken: we refer to it below
        set -x
        scp -p "lpgs@r-dm.nci.org.au:/g/data/v10/agdc/backup/archive/105-${dump_id}-datacube.pgdump" "${dump_file}"
        set +x
    fi

    # Record date/time of DB backup, cubedash will show it as last update time
    date -r "${dump_file}" > "${summary_dir}/generated.txt"

    createdb "$dbname"

    # TODO: the dump has "create extension" statements which will fail (but that's ok here)
    log_info "Restoring"
    # "no data for failed tables": when postgis extension fails to (re)initialise, don't populate its data
    # owner, privileges and tablespace are all NCI-specific.
    pg_restore -v --no-owner --no-privileges --no-tablespaces --no-data-for-failed-tables -d "${dbname}" -j 4 "${dump_file}" || true

    # Hygiene
    log_info "Vacuuming"
    psql "${dbname}" -c "vacuum analyze;"
fi

## Collect query stats on the new DB and remove the dump file
psql "${dbname}" -c "create extension if not exists pg_stat_statements;"

[[ -e "${dump_file}" ]] && rm -v "${dump_file}"

## Summary generation
## get list of products
psql "${dbname}" -X -c 'copy (select name from agdc.dataset_type order by name asc) to stdout' > "${summary_dir}/all-products.txt"

## Will load `datacube.conf` from current directory. Cubedash will use this directory too.
echo "
[datacube]
db_database: ${dbname}
db_hostname: ${PGHOST}
db_port:     5432
db_username: ${PGUSER}
" > datacube.conf

log_info "Summary gen"

$python -m cubedash.generate -C datacube.conf --all || true

echo "Clustering $(date)"
psql "${dbname}" -X -c 'cluster cubedash.dataset_spatial using "dataset_spatial_dataset_type_ref_center_time_idx";'
psql "${dbname}" -X -c 'create index tix_region_center ON cubedash.dataset_spatial (dataset_type_ref, region_code text_pattern_ops, center_time);'
echo "Done $(date)"

## Copy datacube configuration to /opt/odc directory
sudo cp datacube.conf /opt/odc/datacube.conf

echo "Testing a summary"
if ! $python -m cubedash.summary.show -C datacube.conf ls8_nbar_scene;
then
    log_info "Summary gen seems to have failed"
    exit 1
fi

## Copy generated text file to app directory
cp -v "${summary_dir}/generated.txt" "${app_dir}/generated.txt"

log_info "All Done $(date) ${summary_dir}"
log_info "Cubedash Database (${dbname}) updated on $(date)"

## Publish cubedash database update to SNS topic
AWS_PROFILE='default'
export AWS_PROFILE="${AWS_PROFILE}"
TOPIC_ARN=$(/opt/conda/bin/aws sns list-topics | grep "cubedash" | cut -f4 -d'"')

log_info "Publish new updated db (${dbname}) to AWS SNS topic"
/opt/conda/bin/aws sns publish --topic-arn "${TOPIC_ARN}" --message "${bit_bucket_branch}:${dbname}"

## Clean old databases
log_info "Cleaning up old DBs"
old_databases=$(psql -X -t -d template1 -c "select datname from pg_database where datname similar to 'nci_\d{8}' and ((now() - split_part(datname, '_', 2)::date) > interval '1 day');")

## Wait for db switch to be completed by k8s pod deployment
sleep 300

for database in ${old_databases};
do
    echo "Dropping ${database}";
    dropdb "${database}";
done;

log_info "All Done $(date) ${summary_dir}"
