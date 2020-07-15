#!/usr/bin/env bash
set -x
BQ_GLOBAL_OPTS="--dataset_id oxygenators"
BQ_QUERY_OPTS="--use_legacy_sql=false --replace -n=0"

bq $BQ_GLOBAL_OPTS query $BQ_QUERY_OPTS --destination_table sofa_results --replace < eicu_sofa_results.sql
bq $BQ_GLOBAL_OPTS query $BQ_QUERY_OPTS --destination_table=eicu_oxygen_therapy < eicu_oxygen_therapy.sql
bq $BQ_GLOBAL_OPTS query $BQ_QUERY_OPTS --destination_table=final_patient_results < eicu_final_patient_results.sql
