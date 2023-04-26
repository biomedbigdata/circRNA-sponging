import argparse
import json
import os


def read_names(path, sep="\t"):
    names = set()
    with open(path, "r") as f:
        for line in f:
            names.add(line.split(sep)[0])
    return names


def get_circRNAs(config_file):
    with open(config_file) as c:
        config = json.load(c)
        out_dir = config['params']['outdir']
        raw = os.path(out_dir, "results", "circRNA", "circRNA_counts_raw.tsv")
        filtered = os.path(out_dir, "results", "circRNA", "circRNA_counts_filtered.tsv")
        return {"raw": read_names(raw), "filtered": read_names(filtered)}
    

def write_stats(polyA, totalRNA, out_base):
    with open(os.path(out_base, "stats.tsv"), "w") as out:
        # header
        out.write("\t".join(["Type", "n_polyA", "n_totalRNA", "n_overlapping",
                             "FP_all", "FP_overlap"])+"\n")
        for t in ["raw", "filtered"]:
            n_tot = len(totalRNA[t])
            n_poly = len(polyA[t])
            fp_all = n_poly / n_tot
            ov = polyA[t].intersection(totalRNA[t])
            fp_ov = len(ov) / n_tot
            out.write("\t".join([t, n_poly, n_tot, len(ov), fp_all, fp_ov])+"\n")


parser = argparse.ArgumentParser(
                    prog='PolyA_statistics',
                    description='Generate circRNA statistics between two pipeline runs')
parser.add_argument('-p', '--polyA', help='circRNA-sponging config file for polyA input data')
parser.add_argument('-t', '--totalRNA', help='circRNA-sponging config file for totalRNA input data')
parser.add_argument('-o', '--outdir', help='Output directory')
args = parser.parse_args()

# read circRNA paths
polyA_d = get_circRNAs(args.polyA)
totalRNA_d = get_circRNAs(args.totalRNA)
# compare counts
write_stats(polyA_d, totalRNA_d, args.outdir)
