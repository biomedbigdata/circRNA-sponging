FROM nfcore/base:1.12.1
LABEL authors="Octavia Ciora" \
      description="Docker image containing all software requirements for the nf-core/circrnasponging pipeline"

# install psirc from git repository
COPY install_psirc.sh /
RUN bash install_psirc.sh

# Install the conda environment
# All conda/bioconda dependencies are listed there
# TODO: UPDATE and FILTER
COPY environment.yml /

RUN conda env create --quiet -f /environment.yml && conda clean -a

# Add conda installation dir to PATH (instead of doing 'conda activate')
ENV PATH /opt/conda/envs/nf-core-circrnasponging/bin:$PATH

# Dump the details of the installed packages to a file for posterity
RUN conda env export --name nf-core-circrnasponging > nf-core-circrnasponging.yml

# Instruct R processes to use these empty files instead of clashing with a local version
RUN touch .Rprofile
RUN touch .Renviron
