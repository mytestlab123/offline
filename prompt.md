Task: Choose right Pipeline Version, which have containers from quay.io
Task Description: 
Get specific pipeline from github
List all its tags and sort them
Start with latest version and tags
check for any containers/ images from community.wave.seqera.io in that tags/ branch
If found then select older tags. i.e. Go for one revision back wards. (from 3.5.1 to 3.5.0)
check for any containers/ images from community.wave.seqera.io in that tags/ branch
Till we find a branch / tag without any wave containers/ images.


### Started with "3.5.1"

❯ cd /tmp/sarek/git/sarek
sarek on  HEAD [?]
❯ nextflow inspect . -profile test --outdir /tmp/out/ -concretize true -format config | grep wave | tee wave.container.conf
process { withName: 'NFCORE_SAREK:SAREK:CONVERT_FASTQ_INPUT:CAT_FASTQ' { container = 'community.wave.seqera.io/library/coreutils:9.5--ae99c88a9b28c264' } }
process { withName: 'NFCORE_SAREK:SAREK:FASTQ_ALIGN_BWAMEM_MEM2_DRAGMAP_SENTIEON:SENTIEON_BWAMEM' { container = 'community.wave.seqera.io/library/sentieon:202308.03--59589f002351c221' } }


### Checkout to with "3.5.0"

sarek on  HEAD [?]
❯ git checkout 3.5.0
Previous HEAD position was 5cc30494a Merge pull request #1640 from nf-core/dev
HEAD is now at ae4dd11ac Merge pull request #1758 from nf-core/dev
nothing added to commit but untracked files present (use "git add" to track)
❯ gst
HEAD detached at 3.5.0

sarek on  HEAD [?]
❯ nextflow inspect . -profile test --outdir /tmp/out/ -concretize true -format config | grep wave | wc -l
2

### This branch/ tag have containers/ images hosted on community.wave.seqera.io, no select older tag

❯ gst
HEAD detached at 3.4.4
Untracked files:
  (use "git add <file>..." to include in what will be committed)
        container.conf

nothing added to commit but untracked files present (use "git add" to track)
sarek on  HEAD [?]
❯ git tag -l | sort | tail -5
3.4.2
3.4.3
3.4.4
3.5.0
3.5.1
sarek on  HEAD [?]
❯ nextflow inspect . -profile test --outdir /tmp/out/ -concretize true -format config | grep wave | wc -l

0

>> nextflow inspect . -profile test --outdir /tmp/out/ -concretize true -format config | tee container.conf

❯ cat container.conf | grep quay | wc -l
97
sarek on  HEAD [?]
❯ cat container.conf | grep wave | wc -l
0


### This branch/ tag dont have any containers/ images hosted on community.wave.seqera.io, no select older tag
### Means all are hosted on quay.io, which is perect "REVISION" for our offline development.
