library(Hmisc, quietly = T)
library(foreach, quietly = T)
library(doParallel, quietly = T)
library(tidyverse, quietly = T)


# Set cores available to perform parallelization
ncores <- detectCores(all.tests = FALSE, logical = TRUE)
# Caution: Recommended that you do not use all cores
registerDoParallel(cores = ncores-1)

setwd("/Users/galerp/Documents/manuscripts/cube3/git_repo/Cube3/Files/")

#Set output directory
output_dir = "/Users/galerp/Desktop/"

# Load files
prop_hpo_full <- read_csv("example_bin_prop.csv")
gene_dx <- read_csv("example_gene_data.csv")
gene_class <- read_csv("gene_classes.csv")

hpo_def <- read_csv("HPO_def_rl_2020-10-12_dl_2021-08-03.csv")

  
# Remove individuals with genetic dx but no age of dx
gene_nodx_age <- gene_dx %>%
  select(ID, Gene,age_genetic_dx) %>%
  filter(!is.na(Gene),!is.na(ID), Gene !="") %>%
  filter(is.na(age_genetic_dx)) %>% 
  unique() 

prop_hpo <- prop_hpo_full %>% 
  filter(ID %nin% gene_nodx_age$ID)
  

#Compose full genetic diagnoses
mono_gene <- gene_dx %>% 
  filter(ID %in% prop_hpo$ID) %>% 
  filter(!is.na(age_genetic_dx))

all_gene <- mono_gene %>% 
  mutate(Gene = "All")

gene_classes <- mono_gene %>% 
  left_join(gene_class %>% 
              select(Gene, Class)) %>% 
  select(-Gene) %>%
  rename(Gene = Class) %>%
  filter(!is.na(Gene)) %>% 
  select(ID, age_genetic_dx, Gene)

#All diagnoses
full_dx <- mono_gene %>% 
  rbind(all_gene) %>% 
  rbind(gene_classes)


#Get list to analyze (n>1)
gene_pats<- full_dx %>%
  select(ID, Gene,age_genetic_dx) %>%
  filter(!is.na(Gene),!is.na(ID), Gene !="") %>% 
  unique()

gene_count <- gene_pats %>%
  count(Gene) %>% 
  filter(n>1)

# Output table
hpo_sig <- matrix(nrow=0, ncol=13) 


s_times <- sort(unique(prop_hpo$start_year))
e_times <- sort(unique(prop_hpo$finish_year))
genes <- unique(gene_count$Gene)
hpos <- unique(prop_hpo$HPO)

#Function to find features at each gene and each time bin
# Allows for parallelization


hpo_fishes <- function(pats_time,yesg_hpo,nog_hpo,t_start,t_end,geno){

  nog_pats <- nog_hpo$ID %>% unique()
  yesg_pats <- yesg_hpo %>%
    pull(ID) %>% unique

  y_hpo_count <- yesg_hpo %>%
    filter(ID%in%yesg_pats) %>%
    count(HPO)

  n_hpo_count <- nog_hpo %>% count(HPO)


  hp_combs_sig <- foreach(i = 1:nrow(y_hpo_count), .combine=rbind) %dopar% {
    hp <- y_hpo_count$HPO[i]
    fish <- matrix(ncol=2,nrow=2)
    fish[is.na(fish)] <- 0
    fish[1,1] <- y_hpo_count[i,2] %>% unlist()


    yesg_yes_hp <- y_hpo_count[i,2]


    fish[1,2] <- length(yesg_pats) - fish[1,1]

    yes_freq <- fish[1,1]/length(yesg_pats)


    if(hp %in% n_hpo_count$HPO){
      fish[2,1] <- n_hpo_count$n[n_hpo_count$HPO==hp]
      no_freq <- fish[2,1]/length(nog_pats)
      fish[2,2] <- length(nog_pats) - fish[2,1]

      nog_yes_hp <- n_hpo_count$n[n_hpo_count$HPO==hp]

    }else{
      fish[2,1] <- 0
      no_freq <- 0

      nog_yes_hp <- 0
    }

    fish <- fish
    fish[2,2] <- length(nog_pats) - fish[2,1]
    #
    ftest = fisher.test(fish)
    pval <- ftest$p.value
    CI_lower <- ftest$conf.int[1]
    CI_upper <- ftest$conf.int[2]
    
    # Haldane-Anscombe correction: Prevents OR of Inf
    if(any(fish==0)){
      fish = fish+0.5
    }
    OR_n <- fish[1,1]/fish[1,2]
    #Calc OR
    OR_d <- fish[2,1]/fish[2,2]


    ppv = yesg_yes_hp/(yesg_yes_hp+nog_yes_hp)


    OR <- OR_n/OR_d

    c(hp, geno, t_start,t_end, ppv, pval, yes_freq,no_freq,OR,CI_lower,CI_upper,length(yesg_pats),length(nog_pats))
  }
 
  hp_combs_sig2 <- as.data.frame(hp_combs_sig)

  names(hp_combs_sig2) <- c('HPO','gene',"start","finish","PPV",'pval',"yes_freq", "no_freq", "OR",
                            "CI_lower","CI_upper","tot_gene_pats","tot_nogene_pats")

  return(hp_combs_sig2)
}


for(g in 1:length(genes)){
  geno <- genes[g]
  print(geno)

  for(t in 1:length(s_times)){
    t_start <- s_times[t]
    t_end <- e_times[t]

    #Already diagnosed patients
    dx_pats <- gene_pats %>%
      #CONSERVATIVE FILTER
      filter(age_genetic_dx <= t_end)

    pats_time <- prop_hpo %>%
      filter(start_year == t_start) %>%
      filter(ID %nin% dx_pats$ID) %>%
      distinct()

    all_g_pats <- gene_pats %>%
      filter(Gene==geno)
    undx_pats <- gene_pats %>%
      filter(Gene==geno) %>%
      #CONSERVATIVE FILTER
      filter(age_genetic_dx > (t_start+0.25) )

    yesg_hpo <- pats_time %>%
      filter(ID %in% undx_pats$ID)
    nog_hpo <- pats_time %>%
      filter(ID %nin% all_g_pats$ID) %>%
      filter(HPO %in% yesg_hpo$HPO)

    uni_hpo = unique(yesg_hpo$HPO)

    if(nrow(yesg_hpo)>0 & length(uni_hpo)>1){

      time_gene_pvals <- hpo_fishes(pats_time,yesg_hpo,nog_hpo,t_start,t_end,geno)
      hpo_sig <- hpo_sig %>% rbind(time_gene_pvals)
    }
    else{}
  }
}


hpo_sig2 <- hpo_sig %>% as.data.frame()


names(hpo_sig2) <- c('HPO','gene',"t_start","t_end","PPV",'pval',"yes_freq", "no_freq", "OR",
                     "CI_lower","CI_upper","tot_gene_pats","tot_nogene_pats")

hpo_sig3 <- hpo_sig2 %>%
  mutate(t_start = as.numeric(as.character(t_start))) %>%
  mutate(t_end = as.numeric(as.character(t_end))) %>%
  mutate(OR = as.numeric(as.character(OR))) %>%
  mutate(CI_lower = as.numeric(as.character(CI_lower))) %>%
  mutate(CI_upper = as.numeric(as.character(CI_upper))) %>%
  
  mutate(pval = as.numeric(as.character(pval))) %>%
  mutate(PPV = as.numeric(as.character(PPV))) %>%
  mutate(no_freq = as.numeric(as.character(no_freq))) %>%
  mutate(yes_freq = as.numeric(as.character(yes_freq))) %>%
  mutate(tot_gene_pats = as.numeric(as.character(tot_gene_pats))) %>%
  mutate(HPO = as.character(HPO)) %>%
  mutate(gene = as.character(gene)) %>%
  mutate(tot_nogene_pats = as.character(tot_nogene_pats)) %>%
  mutate(yes_npats = tot_gene_pats*yes_freq) %>%
  left_join(hpo_def)

write_csv(hpo_sig3, paste0(output_dir,"gene_fish_3month_consv.csv"))






