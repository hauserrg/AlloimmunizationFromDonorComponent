# load in library
library(ccoptimalmatch)
library(dplyr)

# read in data
dat <- read.table("../1_data/data.txt", header = TRUE, sep = "\t", na.strings=c("NA", "NULL"))
dat$RecipAge <- as.integer(dat$RecipAge)
dat$ID <- 1:nrow(dat)
table(dat$CaseControl)
round(colMeans(is.na(dat)) * 100, 2)

# data pre-processing
# drop variable DonorFerritin
dat <- dat[,-18]
# outlier for numerical variables
dat[which(dat$DonorHb > 25.6),]$DonorHb <- NA
dat[which(dat$DonorHeight > 95),]$DonorHeight <- NA
dat[which(dat$DonorWeight > 600),]$DonorWeight <- NA
# if `DonorSex`=Male, assign ` Not Applicable ` to `DonorPreg` 
dat$DonorPreg <- ifelse(dat$DonorSex=="M", 'N', dat$DonorPreg)
# data consistency for categorical variables
dat[which(dat$DonorTransfuse == '9'),]$DonorTransfuse <- NA
dat[which(dat$DonorBornUSA == '9'),]$DonorBornUSA <- NA
dat[which(dat$DonorEdu == 'S'| dat$DonorEdu == '9'),]$DonorEdu <- NA
dat[which(dat$DonorPreg == '9'),]$DonorPreg <- NA
dat[which(dat$DonorSmoke == '9'),]$DonorSmoke <- NA
# replace Unknow to NA
dat[which(dat$DonorRace == 'Unknown'),]$DonorRace <- NA
dat[which(dat$DonorABO == 'Unknown'),]$DonorABO <- NA
dat[which(dat$DonorRh == 'Unknown'),]$DonorRh <- NA
# check missing value
round(colMeans(is.na(dat)) * 100, 4)
# replace the missing value in ICD code with "Unknown"
dat[,c(27:35)] <- as.data.frame(lapply(dat[,c(27:35)], as.character))
dat[,c(27:35)] <- lapply(dat[,c(27:35)], function(x) ifelse(is.na(x), "Unknown", x)) %>% data.frame()
# add a missing donor variables count for each row
dat$missing_count = rowSums(is.na(dat[,c(5:20)]))
# delete the case that Recipient features (RecipAge, RecipGender, RecipRace, RecipEthnicity) are missing (total 4)
dat <- dat[complete.cases(dat[,c(21:26)]), ]

# Prepare the dataset to be analyzed
# Step 1:Exact Matching on several variables
# case missing donor features
table(dat%>%filter(CaseControl==1)%>%select(missing_count))/3784*100
table(dat%>%filter(CaseControl==0)%>%select(missing_count))/159695*100
# unique subset
create_subset <- dat %>%
  filter(CaseControl == 1) %>%
  filter(missing_count<=10) %>%
  arrange(RecipGender, RecipRace, RecipEthnicity, RecipABO, RecipRh,
          Cancer, Leukemia, MDS, RA, SCD, SickleTrait, SLE, Transplant) %>%
  distinct(RecipGender, RecipRace, RecipEthnicity, RecipABO, RecipRh,
           Cancer, Leukemia, MDS, RA, SCD, SickleTrait, SLE, Transplant,
           .keep_all = TRUE) %>%
  mutate(subset = 1:n()) %>%
  select(RecipGender, RecipRace, RecipEthnicity, RecipABO, RecipRh,
         Cancer, Leukemia, MDS, RA, SCD, SickleTrait, SLE, Transplant, 
         subset)
case_with_subset <- dat %>% 
  filter(CaseControl == 1) %>%
  filter(missing_count<=10) %>%
  left_join(create_subset, by = c("RecipGender", "RecipRace", "RecipEthnicity", 
                                  "RecipABO", "RecipRh",
                                  "Cancer", "Leukemia", "MDS", "RA", 
                                  "SCD", "SickleTrait", "SLE", "Transplant"))
control_with_subset <- dat %>% 
  filter(CaseControl == 0) %>%
  filter(missing_count<=2) %>%
  inner_join(create_subset, by = c("RecipGender", "RecipRace", "RecipEthnicity", 
                                   "RecipABO", "RecipRh",
                                   "Cancer", "Leukemia", "MDS", "RA", 
                                   "SCD", "SickleTrait", "SLE", "Transplant"))
dat_new <- rbind(case_with_subset, control_with_subset)
table(dat_new$CaseControl)
round(colMeans(is.na(dat_new)) * 100, 2)

# Step 2: Create artifical observations and select the range of variables
bdd_controls <- dat_new[dat_new$CaseControl==0,]
bdd_controls$cluster_case <- 0
bdd_cases <- dat_new[dat_new$CaseControl==1,]
bdd_cases$cluster_case <- paste("case",1:nrow(bdd_cases),sep = "_")
dat_new <- rbind(bdd_cases, bdd_controls)
bdd_temp <- data.frame()
list_p <- unique(bdd_cases$cluster_case)
for(i in 1:length(list_p)){
  temp <- bdd_cases %>% filter(cluster_case==list_p[i])
  subset_identified <- temp$subset
  temp0 <- bdd_controls %>% filter(subset==temp$subset)
  temp_final <- rbind(temp,temp0)
  temp_final$cluster_case <- list_p[i]
  temp_final <- temp_final %>%
    group_by(cluster_case) %>%
    mutate(RecipAge_diff = abs(RecipAge - RecipAge[CaseControl==1]))
  temp_final <- temp_final %>% filter(RecipAge_diff <= 10)
  bdd_temp <- rbind(bdd_temp,temp_final)
  if (i %% 100 == 0) {print(paste(i, "-", nrow(bdd_temp)))}
}

# Step 3: Create the variables "total controls per case" and "frequency of controls"
# total controls per case: how many controls are matched for this case
bdd = bdd_temp %>% group_by(cluster_case) %>% mutate(total_control_per_case = n()-1)
bdd$case_control <- ifelse(bdd$CaseControl==1,"case","control")
# frequency of controls: how many cases are matched for this control
bdd = bdd %>% group_by(ID) %>% mutate(freq_of_controls = n())

# Step 4: Order variables
bdd = bdd[order(bdd$cluster_case, bdd$case_control, bdd$RecipAge_diff, bdd$freq_of_controls),]

# Analysis of data
round(colMeans(is.na(bdd)) * 100, 4)
bdd_new = bdd
bdd_new[,c(5:20)] <- as.data.frame(lapply(bdd[,c(5:20)], as.character))
bdd_new[,c(5:20)] <- lapply(bdd_new[,c(5:20)], function(x) ifelse(is.na(x), "NULL", x)) %>% data.frame()
final_data <- optimal_matching(bdd_new, n_con=4, cluster_case, ID, total_control_per_case, case_control, with_replacement = FALSE)
table(final_data$CaseControl)
final_data <- final_data %>% 
  arrange(cluster_case) %>% 
  group_by(cluster_case) %>% 
  mutate(total_control_matched = n()-1)
table(final_data$CaseControl, final_data$total_control_matched)

# save dataset after matching which is used in the main analysis
write.csv(bdd_new, "../1_data/dat_matchingpool.csv")
write.csv(final_data,"../1_data/dat_aftermatching.csv")