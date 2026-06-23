Task: Run and Document process for "scrnaseq" execution (Nextflow Pipeline ) in offline
Task Description: 
Source: https://github.com/nf-core/scrnaseq/blob/2.7.1/
Version: Pipeline: scrnaseq@2.7.1

Run this pipeline on Online ENV and Offline ENV
Follow GETTING_STARTED.md GUIDE

Data Prepartion:

Did you prepare Data Test for Pipeline?
Did you prepare Data Test for Pipeline by studying minimum "test.config"?
Need to download all required inputs and data ref files into "data" folder. i.e. ~/offline/scrnaseq/data
Add "scrnaseq/data" into .gitignore
Check data?

Config Preparation:

Source: 
Local: ~/offline/scrnaseq/scrnaseq/conf/test.config
Online GitHub: https://github.com/nf-core/scrnaseq/blob/2.7.1/conf/test.config

I think, setup.sh just overwrite "~/offline/scrnaseq/test.config" on "~/offline/scrnaseq/scrnaseq/conf/test.config"

why and where we overwrite "test.config"? can you update "setup.sh"? in past, we have pre-configured "test.config". Here we are creating Pipeline using codex first time. 


```
❯ rg test.config common/pipeline/setup.sh
112:rm -f conf/test.config && ln -sv "${CALL_DIR}/test.config" conf/test.config 2>/dev/null || true
```

We always create this file using data test or data preparation steps.

It is my mistake that "GETTING_STARTED.md" documentation or all past pipeline preparation, never explain how "test.config" is to prepare or handle it.



