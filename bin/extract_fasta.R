#!/usr/bin/env Rscript

library(BSgenome)
library(Biostrings)
library(GenomicRanges)
library(GenomicFeatures)
library(seqinr)

args = commandArgs(trailingOnly = TRUE)

genome.version <- args[1]
genomes <- available.genomes(splitNameParts=TRUE)
select.genome <- genomes$pkgname[genomes$genome == genome.version]
if (length(select.genome) == 0) {
  stop("Error: Genome version not found in BSgenomes")
}
# select default genome
select.genome <- select.genome[!grepl("masked", select.genome)]
BiocManager::install(select.genome)
library(package = select.genome, character.only = T)
fasta <- getBSgenome(select.genome)
# load circ expression
circ.expression <- read.table(args[2], sep = "\t", header = T)
# build Granges
ci.expression <- circ.expression[circ.expression$type == "ciRNA",]
circ.expression <- circ.expression[circ.expression$type == "circRNA",]
circ.ranges <- makeGRangesFromDataFrame(circ.expression[,1:4])
ci.ranges <- makeGRangesFromDataFrame(ci.expression[,1:4])
# set names according to annotation
if ("circBaseID" %in% colnames(circ.expression)) {
  names(circ.ranges) <- circ.expression$circBaseID
  names(ci.ranges) <- ci.expression$circBaseID
} else {
  names(circ.ranges) <- paste0(circ.expression$chr, ":", circ.expression$start, "-", circ.expression$stop, "_", circ.expression$strand)
  names(ci.ranges) <- paste0(ci.expression$chr, ":", ci.expression$start, "-", ci.expression$stop, "_", ci.expression$strand)
}

# load gtf
gtf.pkg <- BiocManager::available(paste0(genome.version, ".knownGene"))
BiocManager::install(gtf.pkg)
library(package = gtf.pkg, character.only = T)
gtf <- eval(parse(text=paste0(gtf.pkg,"::",gtf.pkg)))
exons <- exons(gtf)

# splice sequences according to circ annotation
circ.exons <- findOverlapPairs(circ.ranges, exons, type = "any")
ids <- names(circ.exons@first)
circ.exons <- circ.exons@second
names(circ.exons) <- ids
circ.sequences <- getSeq(fasta, circ.exons)
# get intronic sequences
ci.sequences <- getSeq(fasta, ci.ranges)
# combine sequences
all.sequences <- c(circ.sequences, ci.sequences)
# concatenate exons from same ids
all.sequences.frame <- as.data.frame(all.sequences)
all.sequences.frame$id <- names(all.sequences)
all.sequences.frame <- aggregate(. ~ id, all.sequences.frame, function(x) paste0(x, collapse = ""))
all.sequences.combined <- DNAStringSet(all.sequences.frame$x)
names(all.sequences.combined) <- all.sequences.frame$id
# write sequences to file
writeXStringSet(all.sequences.combined, filepath = "circRNAs.fa")