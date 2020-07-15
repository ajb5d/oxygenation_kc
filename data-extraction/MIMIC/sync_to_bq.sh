#!/usr/bin/env bash
set -x
BQ_GLOBAL_OPTS="--dataset_id oxygenators"
BQ_QUERY_OPTS="--use_legacy_sql=false --replace -n=0"

bq $BQ_GLOBAL_OPTS query $BQ_QUERY_OPTS --destination_table icd_codes --replace < icd_codes.sql
bq $BQ_GLOBAL_OPTS query $BQ_QUERY_OPTS --destination_table fluid_balance --replace < fluid_balance.sql
bq $BQ_GLOBAL_OPTS query $BQ_QUERY_OPTS --destination_table mechanical_ventilative_volume --replace < mechanical_ventilative_volume.sql
bq $BQ_GLOBAL_OPTS query $BQ_QUERY_OPTS --destination_table mimic_oxygen_therapy --replace < mimic_oxygen_therapy.sql
bq $BQ_GLOBAL_OPTS query $BQ_QUERY_OPTS --destination_table mimic_final_patient_results --replace < mimic_final_patient_results.sql