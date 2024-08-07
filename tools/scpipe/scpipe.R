err_foo <- function() {
    cat(geterrmessage(), file = stderr())
    q("no", 1, F)
}
options(show.error.messages = F, error = err_foo)

# we need that to not crash galaxy with an UTF8 error on German LC settings.
loc <- Sys.setlocale("LC_MESSAGES", "en_US.UTF-8")

suppressPackageStartupMessages({
    library(scPipe)
    library(SingleCellExperiment)
    library(optparse)
    library(readr)
    library(ggplot2)
    library(plotly)
    library(DT)
    library(scater)
    library(scran)
    library(scales)
    library(Rtsne)
})

option_list <- list(
    make_option(c("-bam", "--bam"), type = "character", help = "BAM file"),
    make_option(c("-fasta", "--fasta"), type = "character", help = "Genome fasta file"),
    make_option(c("-exons", "--exons"), type = "character", help = "Exon annotation gff3 file"),
    make_option(c("-organism", "--organism"), type = "character", help = "Organism e.g. hsapiens_gene_ensembl"),
    make_option(c("-barcodes", "--barcodes"), type = "character", help = "Cell barcodes csv file"),
    make_option(c("-read1", "--read1"), type = "character", help = "Read 1 fastq.gz"),
    make_option(c("-read2", "--read2"), type = "character", help = "Read 2 fastq.gz"),
    make_option(c("-samplename", "--samplename"), type = "character", help = "Name to use for sample"),
    make_option(c("-bs1", "--bs1"), type = "integer", help = "Barcode start in Read 1"),
    make_option(c("-bl1", "--bl1"), type = "integer", help = "Barcode length in Read 1"),
    make_option(c("-bs2", "--bs2"), type = "integer", help = "Barcode start in Read 2"),
    make_option(c("-bl2", "--bl2"), type = "integer", help = "Barcode length in Read 2"),
    make_option(c("-us", "--us"), type = "integer", help = "UMI start in Read 2"),
    make_option(c("-ul", "--ul"), type = "integer", help = "UMI length in Read 2"),
    make_option(c("-rmlow", "--rmlow"), type = "logical", help = "Remove reads with N in barcode or UMI"),
    make_option(c("-rmN", "--rmN"), type = "logical", help = "Remove reads with low quality"),
    make_option(c("-minq", "--minq"), type = "integer", help = "Minimum read quality"),
    make_option(c("-numbq", "--numbq"), type = "integer", help = "Maximum number of bases below minq"),
    make_option(c("-stnd", "--stnd"), type = "logical", help = "Perform strand-specific mapping"),
    make_option(c("-max_mis", "--max_mis"), type = "integer", help = "Maximum mismatch allowed in barcode"),
    make_option(c("-UMI_cor", "--UMI_cor"), type = "integer", help = "Correct UMI sequence error"),
    make_option(c("-gene_fl", "--gene_fl"), type = "logical", help = "Remove low abundant genes"),
    make_option(c("-max_reads", "--max_reads"), type = "integer", help = "Maximum reads processed"),
    make_option(c("-min_count", "--min_count"), type = "integer", help = "Minimum count to keep"),
    make_option(c("-metrics_matrix", "--metrics_matrix"), type = "logical", help = "QC metrics matrix"),
    make_option(c("-keep_outliers", "--keep_outliers"), type = "logical", help = "Keep outlier cells"),
    make_option(c("-report", "--report"), type = "logical", help = "HTML report of plots"),
    make_option(c("-rdata", "--rdata"), type = "logical", help = "Output RData file"),
    make_option(c("-nthreads", "--nthreads"), type = "integer", help = "Number of threads")
)

parser <- OptionParser(usage = "%prog [options] file", option_list = option_list)
args <- parse_args(parser)

bam <- args$bam
fa_fn <- args$fasta
anno_fn <- args$exons
fq_r1 <- args$read1
fq_r2 <- args$read2
read_structure <- list(
    bs1 = args$bs1, # barcode start position in fq_r1, -1 indicates no barcode
    bl1 = args$bl1, # barcode length in fq_r1, 0 since no barcode present
    bs2 = args$bs2, # barcode start position in fq_r2
    bl2 = args$bl2, # barcode length in fq_r2
    us = args$us, # UMI start position in fq_r2
    ul = args$ul # UMI length
)

if (args$us == -1) {
    has_umi <- FALSE
} else {
    has_umi <- TRUE
}

filter_settings <- list(
    rmlow = args$rmlow,
    rmN = args$rmN,
    minq = args$minq,
    numbq = args$numbq
)

# Outputs
out_dir <- "."
mapped_bam <- file.path(out_dir, "aligned.mapped.bam")

# if input is fastqs
if (!is.null(fa_fn)) {
    fasta_index <- file.path(out_dir, paste0(fa_fn, ".fasta_index"))
    combined_fastq <- file.path(out_dir, "combined.fastq")
    aligned_bam <- file.path(out_dir, "aligned.bam")

    print("Trimming barcodes")
    sc_trim_barcode(combined_fastq,
        fq_r1,
        fq_r2,
        read_structure = read_structure,
        filter_settings = filter_settings
    )

    print("Building genome index")
    Rsubread::buildindex(basename = fasta_index, reference = fa_fn)

    print("Aligning reads to genome")
    Rsubread::align(
        index = fasta_index,
        readfile1 = combined_fastq,
        output_file = aligned_bam,
        nthreads = args$nthreads
    )

    if (!is.null(args$barcodes)) {
        barcode_anno <- args$barcodes
    } else {
        print("Detecting barcodes")
        # detect 10X barcodes and generate sample_index.csv file
        barcode_anno <- "sample_index.csv"
        sc_detect_bc(
            infq = combined_fastq,
            outcsv = barcode_anno,
            bc_len = read_structure$bl2,
            max_reads = args$max_reads,
            min_count = args$min_count,
            max_mismatch = args$max_mis
        )
    }
} else {
    aligned_bam <- file.path(out_dir, bam)
    barcode_anno <- args$barcodes
}

print("Assigning reads to exons")
sc_exon_mapping(aligned_bam, mapped_bam, anno_fn, bc_len = read_structure$bl2, UMI_len = read_structure$ul, stnd = args$stnd)

print("De-multiplexing data")
sc_demultiplex(mapped_bam, out_dir, barcode_anno, has_UMI = has_umi)

print("Counting genes")
sc_gene_counting(out_dir, barcode_anno, UMI_cor = args$UMI_cor, gene_fl = args$gene_fl)

print("Performing QC")
sce <- create_sce_by_dir(out_dir)
pdf("plots.pdf")
plot_demultiplex(sce)
if (has_umi) {
    p <- plot_UMI_dup(sce)
    print(p)
}
sce <- calculate_QC_metrics(sce)
sce <- detect_outlier(sce)
p <- plot_mapping(sce, percentage = TRUE, dataname = args$samplename)
print(p)
p <- plot_QC_pairs(sce)
print(p)
dev.off()

print("Removing outliers")
if (is.null(args$keep_outliers)) {
    sce <- remove_outliers(sce)
    gene_counts <- counts(sce)
    write.table(data.frame("gene_id" = rownames(gene_counts), gene_counts), file = "gene_count.tsv", sep = "\t", quote = FALSE, row.names = FALSE)
}

if (!is.null(args$metrics_matrix)) {
    metrics <- colData(sce, internal = TRUE)
    write.table(data.frame("cell_id" = rownames(metrics), metrics), file = "metrics_matrix.tsv", sep = "\t", quote = FALSE, row.names = FALSE)
}

if (!is.null(args$report) & (!is.null(fa_fn))) {
    print("Creating report")
    create_report(
        sample_name = args$samplename,
        outdir = out_dir,
        r1 = fq_r1,
        r2 = fq_r2,
        outfq = combined_fastq,
        read_structure = read_structure,
        filter_settings = filter_settings,
        align_bam = aligned_bam,
        genome_index = fasta_index,
        map_bam = mapped_bam,
        exon_anno = anno_fn,
        stnd = args$stnd,
        fix_chr = FALSE,
        barcode_anno = barcode_anno,
        max_mis = args$max_mis,
        UMI_cor = args$UMI_cor,
        gene_fl = args$gene_fl,
        organism = args$organism,
        gene_id_type = "ensembl_gene_id"
    )
}

if (!is.null(args$rdata)) {
    save(sce, file = file.path(out_dir, "scPipe_analysis.RData"))
}

sessionInfo()
