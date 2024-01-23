/*
Steps:
1. Using the load flat file wizard, I added the donations table in 3 parts. I was getting a memory error, so I split the file.


*/
--drop table [dbo].[donations]

--merge tables (n=2,547,278)
select *
into [dbo].[donations]
from (
	select * from donations1_3 union all
	select * from donations2_3 union all
	select * from donations3_3
) t

--drop table donations1_3
--drop table donations2_3
--drop table donations3_3

--Drop duplicate DINs
drop table if exists donations_filtered
select *
into donations_filtered
from donations d
where DIN_RANDOM is not null and not exists (
	select DIN_RANDOM, count(1) total
	from donations t
	where d.DIN_RANDOM = t.DIN_RANDOM
	group by DIN_RANDOM
	having count(1) > 1
)



select top 100 * 
from donations

--Infectious disease testing removed
select top 100 DONORID_RANDOM, CONTACTINDEX, DIN_RANDOM, DONYR, DONMO, DAYS_BTW_CONTACTS, DAYSLASTHB_1STCONTACT, 
	AGE, SEX, PREVSCRNHX, FIXED, SPONSORTYPE, DONTYPE, DONPROC, REACTION, OUTCOME, ABO_RH, HB_VALUE, 
	COLLECTIONVOLUME, HEIGHT_FEET, HEIGHT_INCHES, WEIGHT, TRANSFUS, TRANSFUS2, BORNUSA, EDUCATION, FTEVER, 
	PREGNANT, NUMPREG, ETHNICITY, RACERECODE, THIRTYDSMOKED, THIRTYDAVGSMOKE, FERRITIN
from donations
where donproc not in ('SO','PP','LP','PL','P2','SC')

