# read in library
library(stats)
library(dplyr)
library(car)
library(caret)
library(mice)
library(forcats)
library(ggplot2)
library(oddsratio)
library(dplyr)
library(forcats)
library(openxlsx)
library(survival)
library(Rcpp)
library(clogitL1)

# load data
dataset <- read.csv("../1_data/dat_aftermatching.csv")[,-1]

# remove variables that are not used in the analysis
dataset <- dataset[,-c(41:43,45:49)]

# Donor Ethnicity
dataset <- dataset %>%
  mutate(DonorEthnicity = case_when(
    RecipEthnicity == "Y" ~ "N",
    RecipEthnicity == "N" ~ "Y",
    RecipEthnicity == "-8" ~ "Unknown",
    TRUE ~ RecipEthnicity
  ))
dataset$DonorEthnicity[which(dataset$DonorRecipEthnicity=="Same")] <- dataset$RecipEthnicity[which(dataset$DonorRecipEthnicity=="Same")]
dataset$DonorEthnicity[which(dataset$DonorRecipEthnicity=="Unknown")] <- "Unknown"
# Recip Ethnicity
dataset$RecipEthnicity[which(dataset$RecipEthnicity=="-8")] <- "Unknown"
# Recip Race
dataset$RecipRace[which(dataset$RecipRace=="-6")] <- "Unknown"
dataset$RecipRace[which(dataset$RecipRace=="-8")] <- "Unknown"

# data pre-processing
dataset[dataset == "NULL"] <- NA
dataset$DonorRecipGender[dataset$DonorRecipGender == "Unknown"] <- NA
dataset$DonorRecipEthnicity[dataset$DonorRecipEthnicity == "Unknown"] <- NA
dataset$DonorRecipRace[dataset$DonorRecipRace == "Unknown"] <- NA
dataset$DonorRecipABO[dataset$DonorRecipABO == "Unknown"] <- NA
dataset$DonorRecipRh[dataset$DonorRecipRh == "Unknown"] <- NA
dataset$DonorEthnicity[dataset$DonorEthnicity == "Unknown"] <- NA

# Number of Case and Control
table(dataset$CaseControl)

# only include variables will be used in multiple imputation
matching_criteria <- dataset[,c(21:35)]
subject <- dataset[,c(2:4)]
dat <- dataset[,c(1,5:8,9:14,16,17,42,18:20,36:41,25,26,29)]

# format data type
num_var <- c(2,7:9,15,16)
dat[,num_var] <- sapply(dat[,num_var], as.numeric)
cat_var <- c(3:6,10:14,17:22,24:26)
for(i in cat_var){
  dat[,i] <- as.factor(fct_infreq(dat[,i]))
}

# missing data pattern checking
dat_missing2 = dat[,-c(23:26)]
# MCAR missingness checking
library(misty)
dat_missing2[,c(3:6,10:14,17:22)] = lapply(dat_missing2[,c(3:6,10:14,17:22)], as.factor)
dat_missing2[,c(3:6,10:14,17:22)] = lapply(dat_missing2[,c(3:6,10:14,17:22)], as.numeric)
na.test(dat_missing2, digits = 2, p.digits = 3, as.na = NULL, check = TRUE, output = TRUE)
# MAR missingness checking
# Create a binary indicator for missingness in DonorDaysLastDonation
dat_missing$missing_DonorDaysLastDonation <- ifelse(is.na(dat_missing$DonorDaysLastDonation), 1, 0)
# Perform logistic regression
logit_model <- glm(missing_DonorDaysLastDonation ~ ., data = dat_missing, family = binomial)
# Summarize the model
summary(logit_model)
# Get the tidy output of the model
tidy(logit_model)

# Sub-analysis of impact of irradiation on alloimmunization
data_SCD = dat[which(matching_criteria$SCD==1),] # SCD = 1: 1365/12836
#In SCD subpopulation, Irradiated yes = 73, no = 1292
data_SCD %>% group_by(CaseControl) %>% select(ProductIrradiated) %>% table() 
model_SCD <- clogit(CaseControl ~ ProductIrradiated + strata(cluster_case), data = data_SCD)
summary(model_SCD)

# check missing value
round(colMeans(is.na(dat[,-c(23:26)])) * 100, 2)
colSums(is.na(dat))

# multiple imputation preparation
set.seed(123)
# We run the mice code with 0 iterations 
imp <- mice(dat, maxit=0)
# Extract predictor Matrix and methods of imputation 
predM <- imp$predictorMatrix
meth <- imp$method
# Setting values of variables I'd like to leave out to 0 in the predictor matrix
predM[c(1:3,5,6,16:26),] <- 0 # don't impute the complete variables, DonorRecipEthnicity, and DonorRecipRace
predM[,c(1,18:23)] <- 0 # don't use DonorRecip variables to impute other missing data
# Turn their methods matrix into the specified imputation models
meth[c(11:14)] <- "logreg"  # Dichotomous variable
meth[c(4)] <- "polyreg" # Unordered categorical variable 
meth

# multiple imputation
set.seed(12345)
imp2 <- mice(dat, m=20, maxit = 20, 
             method = meth, predictorMatrix = predM,
             print = FALSE)
# save and load results of multiple imputation
saveRDS(imp2, file = "multiple_imputation.rda")
imp2 = readRDS("../1_data/multiple_imputation.rda")

# complete data after imputation
completed_data_list <- list()
for (i in 1:20) {
  completed_data <- complete(imp2, action = i)
  # recode DonorRecipGender, DonorRecipRace
  completed_data$DonorRecipEthnicity = as.factor(fct_infreq(
    ifelse(completed_data$DonorEthnicity==matching_criteria$RecipEthnicity, "Same", "Different")))
  completed_data$DonorRecipRace = as.factor(fct_infreq(
    ifelse(completed_data$DonorRace==matching_criteria$RecipRace, "Same", "Different")))
  # create BMI
  completed_data$DonorBMI <- round(703*completed_data$DonorWeight/completed_data$DonorHeight^2,1)
  completed_data <- completed_data %>%
    mutate(DonorBMI_Cat = case_when(
      DonorBMI < 18.5 ~ "Underweight",
      DonorBMI >=18.5 & DonorBMI <= 24.9 ~ "Normal",
      DonorBMI >=25 & DonorBMI <=29.9 ~ "Overweight",
      DonorBMI >=30 ~ "Obesity"
    ))
  # create ABO-black/non-black
  completed_data$ABO_race <- with(completed_data, ifelse(
    DonorRace == "B", 
    paste0(DonorABO, "_black"), 
    paste0(DonorABO, "_non_black")
  ))
  # create categorical storage duration
  completed_data = completed_data %>%
    mutate(ProductDays_Cat = case_when(
      ProductDays < 12 ~ "< 12 days",
      ProductDays >= 34 ~ "> 34 days",
      TRUE ~ "12-34 days"
    ))
  completed_data$ProductDays_Cat = factor(completed_data$ProductDays_Cat)
  completed_data$ProductDays_Cat = relevel(completed_data$ProductDays_Cat, ref = "12-34 days")
  completed_data_list[[i]] <- completed_data
}

# univariate CLR
# Create a list to store  model results
model_DonorAge <- list()
model_DonorSex <- list()
model_DonorRace <- list()
model_DonorABO <- list()
model_DonorRh <- list()
model_DonorHb <- list()
model_DonorTransfuse <- list()
model_DonorBornUSA <- list()
model_DonorPreg <- list()
model_DonorSmoke <- list()
model_DonorDaysLastDonation <- list()
model_DonorEthnicity <- list()
model_ProductDays <- list()
model_ProductIrradiated <- list()
model_DonorRecipGender <- list()
model_DonorRecipEthnicity <- list()
model_DonorRecipRace <- list()
model_DonorRecipABO <- list()
model_DonorRecipRh <- list()
model_DonorBMI_Cat <- list()
model_DonorABO_Race <- list()
model_ProductDays_Cat <- list()
for (i in 1:20){
  completed_data = completed_data_list[[i]]
  model_DonorAge[[i]] <- clogit(CaseControl ~ DonorAge + strata(cluster_case), data = completed_data)
  model_DonorSex[[i]] <- clogit(CaseControl ~ DonorSex + strata(cluster_case), data = completed_data)
  model_DonorRace[[i]] <- clogit(CaseControl ~ DonorRace + strata(cluster_case), data = completed_data)
  model_DonorABO[[i]] <- clogit(CaseControl ~ DonorABO + strata(cluster_case), data = completed_data)
  model_DonorRh[[i]] <- clogit(CaseControl ~ DonorRh + strata(cluster_case), data = completed_data)
  model_DonorHb[[i]] <- clogit(CaseControl ~ DonorHb + strata(cluster_case), data = completed_data)
  model_DonorTransfuse[[i]] <- clogit(CaseControl ~ DonorTransfuse + strata(cluster_case), data = completed_data)
  model_DonorBornUSA[[i]] <- clogit(CaseControl ~ DonorBornUSA + strata(cluster_case), data = completed_data)
  model_DonorPreg[[i]] <- clogit(CaseControl ~ DonorPreg + strata(cluster_case), data = completed_data)
  model_DonorSmoke[[i]] <- clogit(CaseControl ~ DonorSmoke + strata(cluster_case), data = completed_data)
  model_DonorDaysLastDonation[[i]] <- clogit(CaseControl ~ DonorDaysLastDonation + strata(cluster_case), data = completed_data)
  model_DonorEthnicity[[i]] <- clogit(CaseControl ~ DonorEthnicity + strata(cluster_case), data = completed_data)
  model_ProductDays[[i]] <- clogit(CaseControl ~ ProductDays + strata(cluster_case), data = completed_data)
  model_ProductIrradiated[[i]] <- clogit(CaseControl ~ ProductIrradiated + strata(cluster_case), data = completed_data)
  model_DonorRecipGender[[i]] <- clogit(CaseControl ~ DonorRecipGender + strata(cluster_case), data = completed_data)
  model_DonorRecipEthnicity[[i]] <- clogit(CaseControl ~ DonorRecipEthnicity + strata(cluster_case), data = completed_data)
  model_DonorRecipRace[[i]] <- clogit(CaseControl ~ DonorRecipRace + strata(cluster_case), data = completed_data)
  model_DonorRecipABO[[i]] <- clogit(CaseControl ~ DonorRecipABO + strata(cluster_case), data = completed_data)
  model_DonorRecipRh[[i]] <- clogit(CaseControl ~ DonorRecipRh + strata(cluster_case), data = completed_data)
  model_DonorBMI_Cat[[i]] <- clogit(CaseControl ~ DonorBMI_Cat + strata(cluster_case), data = completed_data)
  model_ProductDays_Cat[[i]] <- clogit(CaseControl ~ ProductDays_Cat + strata(cluster_case), data = completed_data)
  model_DonorABO_Race[[i]] <- clogit(CaseControl ~ ABO_race + strata(cluster_case), data = completed_data)
}
uni_model <- summary(pool(model_DonorAge), conf.int = TRUE) %>% data.frame() %>%
  rbind(summary(pool(model_DonorSex), conf.int = TRUE) %>% data.frame()) %>% 
  rbind(summary(pool(model_DonorRace), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_DonorEthnicity), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_DonorABO), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_DonorRh), conf.int = TRUE) %>% data.frame())%>%
  rbind(summary(pool(model_DonorHb), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_DonorBMI_Cat), conf.int = TRUE) %>% data.frame())%>%
  rbind(summary(pool(model_DonorTransfuse), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_DonorBornUSA), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_DonorPreg), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_DonorSmoke), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_DonorDaysLastDonation), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_ProductDays), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_ProductIrradiated), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_DonorRecipGender), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_DonorRecipEthnicity), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_DonorRecipRace), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_DonorRecipABO), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_DonorRecipRh), conf.int = TRUE) %>% data.frame())%>%
  rbind(summary(pool(model_DonorABO_Race), conf.int = TRUE) %>% data.frame())%>%
  rbind(summary(pool(model_ProductDays_Cat), conf.int = TRUE) %>% data.frame())
uni_model$or <- exp(uni_model$estimate)
uni_model$ci_low <- exp(uni_model[,7])
uni_model$ci_up <- exp(uni_model[,8])
uni_model[which(uni_model$p.value<0.1),1]

# elastic net penalty 
var_select = list()

for (i in 1:20){
  completed_data = completed_data_list[[i]]
  X = completed_data[,c(2:7,10:22,28)]
  # convert categorical variables to numerical variables
  X[,c(2:5,7:11,14:20)] = X[,c(2:5,7:11,14:20)] %>% mutate(across(everything(), ~ as.numeric(as.factor(.))))
  
  clObj = clogitL1(x=X, y=completed_data$CaseControl, strata=as.factor(completed_data$cluster_case), alpha = 0.5)
  clcvObj = cv.clogitL1(clObj)
  optimal_lambda_index = which.min(clcvObj$mean_cv)
  selected_beta = clObj$beta[optimal_lambda_index, ]
  selected_variables = which(selected_beta != 0)
  var_select[[i]] = colnames(X)[selected_variables]
}

var_select_all = unlist(var_select)
table(var_select_all)

# Elastic Net penalty: DonorABO DonorAge DonorDaysLastDonation DonorRecipRh ProductDays ProductIrradiated
# univariate CLR: DonorAge DonorABO DonorRh DonorRace ProductDays ProductIrradiated DonorRecipABO DonorRecipRh
# all: DonorAge DonorRh DonorABO DonorRace DonorDaysLastDonation ProductDays ProductIrradiated DonorRecipRh DonorRecipABO

# multivariate CLR
# Original model
model_results <- list()
for (i in 1:20) {
  completed_data = completed_data_list[[i]]
  
  model <- clogit(CaseControl ~ DonorAge+DonorRace+DonorRh+
                    DonorDaysLastDonation+ProductDays+
                    ProductIrradiated+DonorRecipABO+DonorRecipRh+
                    strata(cluster_case),
                  data = completed_data)
  model_results[[i]] <- model
}
# check multicollinearity
vif_model <- vif(model)
print(vif_model) # exclude DonorABO in the multivariable model due to multicollinearity with DonorRecipABO
pooled_model <- pool(model_results)
#step(pooled_model,direction="backward",trace=FALSE)
result <- as.data.frame(summary(pooled_model,conf.int = TRUE))
result$or <- exp(result$estimate)
result$ci_low <- exp(result[,7])
result$ci_up <- exp(result[,8])
result[which(result$p.value<0.1),1]

# single transfusion subset analysis
# select subset
dataset$SubjectTotal = subject$SubjectTotal
case_sub <- dataset %>% filter(SubjectTotal == 1) %>% select(cluster_case) %>% unique() 
dat_sub <- dataset[which(dataset$cluster_case %in% c(case_sub[,1])),]
# matching results of subset
dat_sub <- dat_sub %>% 
  arrange(cluster_case) %>% 
  group_by(cluster_case) %>% 
  mutate(total_control_matched = n()-1)
table(dat_sub$CaseControl, dat_sub$total_control_matched)

# complete subset after imputation
completed_subset_list <- list()
for (i in 1:20) {
  completed_data <- completed_data_list[[i]]
  # select subset
  completed_data$SubjectTotal = subject$SubjectTotal
  case_sub <- completed_data %>% filter(SubjectTotal == 1) %>% select(cluster_case) %>% unique() 
  dat_sub <- completed_data[which(completed_data$cluster_case %in% c(case_sub[,1])),]
  completed_subset_list[[i]] <- dat_sub
}

# univariate CLR for subset
# Create a list to store  model results
model_DonorAge <- list()
model_DonorSex <- list()
model_DonorRace <- list()
model_DonorABO <- list()
model_DonorRh <- list()
model_DonorHb <- list()
model_DonorTransfuse <- list()
model_DonorBornUSA <- list()
model_DonorPreg <- list()
model_DonorSmoke <- list()
model_DonorDaysLastDonation <- list()
model_DonorEthnicity <- list()
model_ProductDays <- list()
model_ProductIrradiated <- list()
model_DonorRecipGender <- list()
model_DonorRecipEthnicity <- list()
model_DonorRecipRace <- list()
model_DonorRecipABO <- list()
model_DonorRecipRh <- list()
model_DonorBMI_Cat <- list()
model_DonorABO_Race <- list()
for (i in 1:20){
  completed_data = completed_subset_list[[i]]
  model_DonorAge[[i]] <- clogit(CaseControl ~ DonorAge + strata(cluster_case), data = completed_data)
  model_DonorSex[[i]] <- clogit(CaseControl ~ DonorSex + strata(cluster_case), data = completed_data)
  model_DonorRace[[i]] <- clogit(CaseControl ~ DonorRace + strata(cluster_case), data = completed_data)
  model_DonorABO[[i]] <- clogit(CaseControl ~ DonorABO + strata(cluster_case), data = completed_data)
  model_DonorRh[[i]] <- clogit(CaseControl ~ DonorRh + strata(cluster_case), data = completed_data)
  model_DonorHb[[i]] <- clogit(CaseControl ~ DonorHb + strata(cluster_case), data = completed_data)
  model_DonorTransfuse[[i]] <- clogit(CaseControl ~ DonorTransfuse + strata(cluster_case), data = completed_data)
  model_DonorBornUSA[[i]] <- clogit(CaseControl ~ DonorBornUSA + strata(cluster_case), data = completed_data)
  model_DonorPreg[[i]] <- clogit(CaseControl ~ DonorPreg + strata(cluster_case), data = completed_data)
  model_DonorSmoke[[i]] <- clogit(CaseControl ~ DonorSmoke + strata(cluster_case), data = completed_data)
  model_DonorDaysLastDonation[[i]] <- clogit(CaseControl ~ DonorDaysLastDonation + strata(cluster_case), data = completed_data)
  model_DonorEthnicity[[i]] <- clogit(CaseControl ~ DonorEthnicity + strata(cluster_case), data = completed_data)
  model_ProductDays[[i]] <- clogit(CaseControl ~ ProductDays + strata(cluster_case), data = completed_data)
  model_ProductIrradiated[[i]] <- clogit(CaseControl ~ ProductIrradiated + strata(cluster_case), data = completed_data)
  model_DonorRecipGender[[i]] <- clogit(CaseControl ~ DonorRecipGender + strata(cluster_case), data = completed_data)
  model_DonorRecipEthnicity[[i]] <- clogit(CaseControl ~ DonorRecipEthnicity + strata(cluster_case), data = completed_data)
  model_DonorRecipRace[[i]] <- clogit(CaseControl ~ DonorRecipRace + strata(cluster_case), data = completed_data)
  model_DonorRecipABO[[i]] <- clogit(CaseControl ~ DonorRecipABO + strata(cluster_case), data = completed_data)
  model_DonorRecipRh[[i]] <- clogit(CaseControl ~ DonorRecipRh + strata(cluster_case), data = completed_data)
  model_DonorBMI_Cat[[i]] <- clogit(CaseControl ~ DonorBMI_Cat + strata(cluster_case), data = completed_data)
  model_DonorABO_Race[[i]] <- clogit(CaseControl ~ ABO_race + strata(cluster_case), data = completed_data)
}
uni_model_subset <- summary(pool(model_DonorAge), conf.int = TRUE) %>% data.frame() %>%
  rbind(summary(pool(model_DonorSex), conf.int = TRUE) %>% data.frame()) %>% 
  rbind(summary(pool(model_DonorRace), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_DonorEthnicity), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_DonorABO), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_DonorRh), conf.int = TRUE) %>% data.frame())%>%
  rbind(summary(pool(model_DonorHb), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_DonorBMI_Cat), conf.int = TRUE) %>% data.frame())%>%
  rbind(summary(pool(model_DonorTransfuse), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_DonorBornUSA), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_DonorPreg), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_DonorSmoke), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_DonorDaysLastDonation), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_ProductDays), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_ProductIrradiated), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_DonorRecipGender), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_DonorRecipEthnicity), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_DonorRecipRace), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_DonorRecipABO), conf.int = TRUE) %>% data.frame())%>% 
  rbind(summary(pool(model_DonorRecipRh), conf.int = TRUE) %>% data.frame())%>%
  rbind(summary(pool(model_DonorABO_Race), conf.int = TRUE) %>% data.frame())
uni_model_subset$or <- exp(uni_model_subset$estimate)
uni_model_subset$ci_low <- exp(uni_model_subset[,7])
uni_model_subset$ci_up <- exp(uni_model_subset[,8])
uni_model_subset[which(uni_model_subset$p.value<0.1),1]

# elastic net penalty
var_select_subset = list()

for (i in 1:20){
  completed_data = completed_subset_list[[i]]
  X = completed_data[,c(2:7,10:22,28)]
  X[,c(2:5,7:11,14:20)] = X[,c(2:5,7:11,14:20)] %>% mutate(across(everything(), ~ as.numeric(as.factor(.))))
  
  clObj = clogitL1(x=X, y=completed_data$CaseControl, strata=as.factor(completed_data$cluster_case))
  clcvObj = cv.clogitL1(clObj)
  optimal_lambda_index = which.min(clcvObj$mean_cv)
  selected_beta = clObj$beta[optimal_lambda_index, ]
  selected_variables = which(selected_beta != 0)
  var_select_subset[[i]] = colnames(X)[selected_variables]
}

var_select_all_subset = unlist(var_select_subset)
table(var_select_all_subset)

# Elastic Net penalty: DonorAge DonorDaysLastDonation ProductDays ProductIrradiated
# univariate CLR: DonorABO ProductDays ProductIrradiated DonorRecipABO DonorRecipRh
# all: DonorAge+DonorABO+DonorDaysLastDonation+ProductDays+ProductIrradiated+DonorRecipABO+DonorRecipRh


# multivariate CLR for subset
model_results_subset <- list()
for (i in 1:20) {
  completed_data = completed_subset_list[[i]]
  
  model <- clogit(CaseControl ~ DonorAge+DonorDaysLastDonation+ProductDays+
                    ProductIrradiated+DonorRecipABO+DonorRecipRh+
                    strata(cluster_case),
                  data = completed_data)
  model_results_subset[[i]] <- model
  #summary(model)
}
#check collinearity
vif(model) # exclude DonorABO due to multicollinearity
pooled_model_subset <- pool(model_results_subset)
result_subset <- as.data.frame(summary(pooled_model_subset,conf.int = TRUE))
result_subset$or <- exp(result_subset$estimate)
result_subset$ci_low <- exp(result_subset[,7])
result_subset$ci_up <- exp(result_subset[,8])

# save the result
library(openxlsx)
# Create Excel workbook
wb <- createWorkbook()
addWorksheet(wb, sheetName = "uni_main")
writeData(wb, sheet = "uni_main", uni_model, rowNames = FALSE)
addWorksheet(wb, sheetName = "multi_main")
writeData(wb, sheet = "multi_main", result, rowNames = FALSE)
addWorksheet(wb, sheetName = "uni_subset")
writeData(wb, sheet = "uni_subset", uni_model_subset, rowNames = FALSE)
addWorksheet(wb, sheetName = "multi_subset")
writeData(wb, sheet = "multi_subset", result_subset, rowNames = FALSE)
saveWorkbook(wb, "../3_result/LR_model.xlsx")

# check the result
result$term[which(result$p.value<0.001)]
result$term[which(result$p.value>0.001 & result$p.value<0.01)]
result$term[which(result$p.value>0.01 & result$p.value<0.05)]
result$term[which(result$p.value>0.05 & result$p.value<0.1)]

# plot odds ratio
# Extract the odds ratio and 95%CI
or <- result[,9]
ci <- result[,c(10,11)]

ci[which(ci[,2]>20),2] <- max(ci[-which(ci[,2]>20),2])+1

# Data frame
data <- data.frame(predictor = result$term,
                   odds_ratio = or, 
                   lower_ci = ci[,1], 
                   upper_ci = ci[,2])

# change orders
data_new <- rbind(data[1,],data[3,],data[2,],data[5,],data[4,],data[6:11,])
boxLabels <- c("DonorAge","DonorRaceA","DonorRaceB","DonorRaceH","DonorRaceI",
               "DonorRhNeg","DonorDaysLastDonation","ProductDays","ProductIrradiatedY",
               "DonorRecipABODifferent","DonorRecipRhDifferent")
data_new$predictor <- factor(data_new$predictor,levels = boxLabels)

# Plot the odds ratio
ggplot(data_new, aes(y = predictor, x = odds_ratio,
                     xmin = lower_ci, xmax = upper_ci)) +
  geom_pointrange() +
  ylab("Predictor Variable") +
  xlab("Odds Ratios") +
  geom_vline(xintercept = 1, linetype = "dashed", color = "grey") +
  theme_bw()+
  theme_light()+
  theme_minimal()+
  scale_y_discrete(limits=rev)