#!/usr/bin/env nextflow
/*
========================================================================================
                         lifebit-ai/biobank-gwas
========================================================================================
 lifebit-ai/biobank-gwas GWAS pipeline built using SAIGE
 #### Homepage / Documentation
 https://github.com/lifebit-ai/biobank-gwas
----------------------------------------------------------------------------------------
*/

/*--------------------------------------------------
  Channel setup
---------------------------------------------------*/
ch_input_cb_data = params.cohort_browser_phenofile ? Channel.value(params.cohort_browser_phenofile) : Channel.empty()
ch_input_meta_data = params.input_meta_data ? Channel.value(params.input_meta_data) : Channel.empty()

Channel
  .fromFilePairs("${params.plinkFile}",size:3, flat : true)
  .ifEmpty { exit 1, "PLINK files not found: ${params.plinkFile}" }
  .set { plinkCh }
Channel
  .fromPath(params.plink_keep_pheno)
  .set {plink_keep_pheno_ch}
Channel
  .fromPath(params.vcfsList)
  .ifEmpty { exit 1, "Cannot find CSV VCFs file : ${params.vcfsList}" }
  .splitCsv(skip:1)
  .map { chr, vcf, index -> [file(vcf).simpleName, chr, file(vcf), file(index)] }
  .set { vcfsCh }
Channel
  .fromPath(params.gwas_cat)
  .ifEmpty { exit 1, "Cannot find GWAS catalogue CSV  file : ${params.gwas_cat}" }
  .set { ch_gwas_cat }


/*--------------------------------------------------
  Ingest output from CB
---------------------------------------------------*/
if (params.cohort_browser_phenofile){
  process transforms_cb_output {
    tag "$name"
    publishDir "${params.outdir}/design_matrix", mode: 'copy'

    input:
    val input_cb_data from ch_input_cb_data
    val input_meta_data from ch_input_meta_data

    output:
    file("${params.outprefix}_.phe") into ch_transform_cb
    file("*.json") into ch_encoding_json

    script:
    """
    cp /opt/bin/* .

    mkdir -p ${params.outdir}/design_matrix
    
    transform_cb_output.R --input_cb_data "${params.cohort_browser_phenofile}" \
                          --input_meta_data "${params.input_meta_data}" \
                          --phenoCol "${params.phenoCol}" \
                          --continuous_var_transformation "${params.continuous_var_transformation}" \
                          --outdir "." \
                          --outprefix "${params.outprefix}"
    """
  }
}
//TODO: Check this later and finish it with the processes 

if (params.cohort_browser_phenofile && params.case_group && params.mode == 'case_vs_control_contrast') {
  process add_design_matrix_case_vs_control_contrast{
    tag "$name"
    publishDir "${params.outdir}/contrasts", mode: 'copy'

    input:
    file(pheFile) from ch_transform_cb
    file(json) from ch_encoding_json

    output:
    file("${params.outprefix}_design_matrix_control_*.phe") into phenoCh_gwas_filtering

    script:
    """
    cp /opt/bin/* .

    mkdir -p ${params.outdir}/contrasts

    create_design.R --input_file ${pheFile} \
                    --mode "${params.mode}" \
                    --case_group "${params.case_group}" \
                    --outdir . \
                    --outprefix ${params.outprefix} \
                    --phenoCol "${params.phenoCol}"
                      
    """
  }
}

if (params.cohort_browser_phenofile &&  params.case_group && params.mode == 'case_vs_groups_contrasts') {
  process add_design_matrix_case_vs_groups_contrasts{
    tag "$name"
    publishDir "${params.outdir}/contrasts", mode: 'copy'

    input:
    file(pheFile) from ch_transform_cb
    file(json) from ch_encoding_json

    output:
    file("${outprefix}_design_matrix_control_*.phe'") into phenoCh_gwas_filtering

    script:
    """
    cp /opt/bin/* .

    mkdir -p ${params.outdir}/contrasts

    create_design.R --input_file ${pheFile} \
                    --case_group "${params.case_group}" \
                    --outdir . \
                    --outprefix ${outprefix} \
                    --phenoCol "${params.phenoCol}"
                      
    """
  }
}

if (params.cohort_browser_phenofile && params.mode == 'all_contrasts') {

  process add_design_matrix_all_contrasts{
    tag "$name"
    publishDir "${params.outdir}/contrasts", mode: 'copy'

    input:
    file(pheFile) from ch_transform_cb

    output:
    file("${outprefix}_design_matrix_control_*.phe'") into phenoCh_gwas_filtering

    script:
    """
    cp /opt/bin/* .

    mkdir -p ${params.outdir}/contrasts

    create_design.R --input_file ${pheFile} \
                    --mode ${params.mode}
                    --outdir . \
                    --outprefix ${outprefix} \
                    --phenoCol "${params.phenoCol}"
                      
    """
  }
}


/*--------------------------------------------------
  Pre-GWAS filtering - download, filter and convert VCFs
---------------------------------------------------*/

process gwas_filtering {
  tag "$name"
  publishDir "${params.outdir}/gwas_filtering", mode: 'copy'

  input:
  set val(name), val(chr), file(vcf), file(index) from vcfsCh
  each file(phenofile) from phenoCh_gwas_filtering
  each file(plink_keep_file) from plink_keep_pheno_ch

  output:
  set val(name), val(chr), file("${name}.filtered_final.vcf.gz"), file("${name}.filtered_final.vcf.gz.csi") into filteredVcfsCh
  file("${name}_filtered.{bed,bim,fam}") into plinkTestCh

  script:
  // TODO: (High priority) Only extract needed individuals from VCF files with `bcftools -S samples.txt` - get from samples file?
  // TODO: (Not required) `bcftools -T sites_to_extract.txt`
  // Optional parameters
  extra_plink_filter_missingness_options = params.plink_keep_pheno != "s3://lifebit-featured-datasets/pipelines/biobank-gwas/testdata/nodata" ? "--keep ${plink_keep_file}" : ""
  """
  # Download, filter and convert (bcf or vcf.gz) -> vcf.gz
  bcftools view -q ${params.qFilter} $vcf -Oz -o ${name}_filtered.vcf.gz
  bcftools index ${name}_filtered.vcf.gz
 
  # Create PLINK binary from vcf.gz
  plink2 \
    --make-bed \
    --set-missing-var-ids @:#,\\\$r,\\\$a \
    --vcf ${name}_filtered.vcf.gz \
    --out ${name}_filtered \
    --vcf-half-call m \
    --double-id \
    --set-hh-missing \
    --new-id-max-allele-len 60 missing

  #Filter missingness
  plink \
    --bfile ${name}_filtered \
    --pheno $phenofile \
    --pheno-name PHE \
    --allow-no-sex \
    --test-missing midp \
    --out ${name} \
    --1 \
    --keep-allele-order \
    ${extra_plink_filter_missingness_options}

  awk '\$5 < ${params.thres_m} {print}' ${name}.missing > ${name}.missing_FAIL

  #Filter HWE
  plink \
    --bfile ${name}_filtered \
    --pheno $phenofile \
    --pheno-name PHE \
    --allow-no-sex \
    --hwe ${params.thres_HWE} midp \
    --out ${name}.misHWEfiltered \
    --make-just-bim \
    --exclude ${name}.missing_FAIL \
    --1 \
    --keep-allele-order \
    ${extra_plink_filter_missingness_options}

  bcftools view ${name}_filtered.vcf.gz | awk -F '\\t' 'NR==FNR{c[\$1\$4\$6\$5]++;next}; c[\$1\$2\$4\$5] > 0' ${name}.misHWEfiltered.bim - | bgzip > ${name}.filtered_temp.vcf.gz
  bcftools view -h ${name}_filtered.vcf.gz -Oz -o ${name}_filtered.header.vcf.gz
  cat ${name}_filtered.header.vcf.gz ${name}.filtered_temp.vcf.gz > ${name}.filtered_final.vcf.gz
  bcftools index ${name}.filtered_final.vcf.gz
  """
}

/*--------------------------------------------------
  GWAS Analysis 1 with SAIGE - Fit the null mixed-model
---------------------------------------------------*/
// Create channel for this process
phenoCh_gwas_filtering.into{phenoCh}

process gwas_1_fit_null_glmm {
  tag "$plink_GRM_snps"
  publishDir "${params.outdir}/gwas_1_fit_null_glmm", mode: 'copy'

  input:
  set val(plink_GRM_snps), file(bed), file(bim), file(fam) from plinkCh
  each file(phenoFile) from phenoCh

  output:
  file "*" into fit_null_glmm_results
  file ("step1_${params.phenoCol.replaceAll(/\s/,'_')}_out.rda") into rdaCh
  file ("step1_${params.phenoCol.replaceAll(/\s/,'_')}.varianceRatio.txt") into varianceRatioCh

  script:
  """
  step1_fitNULLGLMM.R \
    --plinkFile=${plink_GRM_snps} \
    --phenoFile="${phenoFile}" \
    --phenoCol="PHE" \
    --sampleIDColinphenoFile=IID \
    --traitType=${params.traitType} \
    --outputPrefix="step1_${params.phenoCol.replaceAll(/\s/,'_')}_out" \
    --outputPrefix_varRatio="step1_${params.phenoCol.replaceAll(/\s/,'_')}" \
    --nThreads=${task.cpus} ${params.saigeStep1ExtraFlags}
  """
}

/*--------------------------------------------------
  GWAS Analysis 2 with SAIGE - Perform mixed-model association testing
---------------------------------------------------*/

process gwas_2_spa_tests {
  tag "$name"
  publishDir "${params.outdir}/gwas_2_spa_tests", mode: 'copy'

  input:
  set val(name), val(chr), file(vcf), file(index) from filteredVcfsCh
  each file(rda) from rdaCh
  each file(varianceRatio) from varianceRatioCh

  output:
  file "*" into results
  file("*.SAIGE.gwas.txt") into ch_report

  script:
  """
  step2_SPAtests.R \
    --vcfFile=${vcf} \
    --vcfFileIndex=${index} \
    --vcfField=GT \
    --chrom=${chr} \
    --minMAC=20 \
    --sampleFile=day0_covid.samples \
    --GMMATmodelFile=${rda} \
    --varianceRatioFile=${varianceRatio} \
    --SAIGEOutputFile="${params.phenoCol.replaceAll(/\s/,'_')}.${name}.SAIGE.gwas.txt" \
    --numLinesOutput=2 \
    --IsOutputAFinCaseCtrl=TRUE \
    --IsDropMissingDosages=FALSE \
    --IsOutputNinCaseCtrl=TRUE \
    --IsOutputHetHomCountsinCaseCtrl=TRUE
  """
}

/*--------------------------------------------------
  GWAS Analysis 2 with SAIGE - Generate report
---------------------------------------------------*/

process create_report {
  tag "report"
  publishDir "${params.outdir}/MultiQC/", mode: 'copy'

  input:
  file(saige_output) from ch_report.collect()
  file(gwas_cat) from ch_gwas_cat

  output:
  file "multiqc_report.html" into ch_report_outputs
  set file("*png"), file("*ipynb"), file("*csv") into ch_report_outputs_all

  script:

  """
  cp /opt/bin/* .
  
  # creates 2 .csv files, saige_results_<params.output_tag>.csv, saige_results_top_n.csv
  concat_chroms.R \
    --saige_output_name='saige_results' \
    --filename_pattern='${params.saige_filename_pattern}' \
    --output_tag='${params.output_tag}' \
    --top_n_sites=${params.top_n_sites} \
    --max_top_n_sites=${params.max_top_n_sites}

  # creates gwascat_subset.csv
  subset_gwascat.R \
    --saige_output='saige_results_${params.output_tag}.csv' \
    --gwas_cat='${gwas_cat}'

  # creates <params.output_tag>_manhattan.png with analysis.csv as input
  manhattan.R \
    --saige_output='saige_results_${params.output_tag}.csv' \
    --output_tag='${params.output_tag}'

  # creates <params.output_tag>_qqplot_ci.png with analysis.csv as input
  qqplot.R \
    --saige_output='saige_results_${params.output_tag}.csv' \
    --output_tag='${params.output_tag}'

  # Generates the report
  Rscript -e "rmarkdown::render('gwas_report.Rmd', params = list(manhattan='${params.output_tag}_manhattan.png',qqplot='${params.output_tag}_qqplot_ci.png', gwascat='gwascat_subset.csv', saige_results='saige_results_top_n.csv'))"
  mv gwas_report.html multiqc_report.html

  # Generates the ipynb
  jupytext --to ipynb gwas_report.Rmd
  """
}
