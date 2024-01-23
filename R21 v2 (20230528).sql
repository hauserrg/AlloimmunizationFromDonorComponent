--------------------------------------------------------------
-- create schema v2
--------------------------------------------------------------------
--	These tables become the events table
--------------------------------------------------------------------
--1. Issued: Beginning with all RBCs issued...
--Retaining the row id, subject, encounter, DIN, date, and days from donation to issue...
--Deriving the window for antibody formation (+15, +112)
drop table if exists v2.issued
select --top 10 
	'Issued' OriginalTable, Id OriginalTableId, SUBJECTID_RANDOM, ENCOUNTERID_RANDOM, DIN_RANDOM collate SQL_Latin1_General_CP1_CS_AS as DIN_RANDOM
	, DAYSSINCESTART1STENCOUNTER, 'RBCTx' EventName
	, cast(DAYSDONATIONTOISSUE as varchar(4)) as DAYSDONATIONTOISSUE
	, DAYSSINCESTART1STENCOUNTER +15 as AbFormDaysStart, DAYSSINCESTART1STENCOUNTER + 112 as AbFormDaysEnd
	, Washed, Irradiated, Leukoreduced, Thawed
into v2.issued
from [dbo].[issuedTxProducts_filtered] f --RBC only
left join Dim_ProductTypeMap m on f.PRODUCTCODE = m.productcode

--2. Tests: Beginning with the screen and antibody identification for patients issued RBCs
--Retaining the row id, subject, date, diagnostic type, result
--Mapping the diagnostic type, result, and antibody clinical significance
--Deriving the ordered occurrence of each specific antibody, positive screens without antibodies identified
--Filtering only the first occurrance of the antibody, removing positive screens without antibodies identified
drop table if exists v2.tests
select --top 1000
	'Diag' OriginalTable, d.Id OriginalTableId, d.SUBJECTID_RANDOM, ENCOUNTERID_RANDOM, 'Test' EventName
	, d.DAYSSINCESTART1STENCOUNTER, case when diagnostictype = 3 then 'Screen' when DIAGNOSTICTYPE = 4 then 'AbId' else null end DiagnosticType	
	, LABRESULTS, case when diagnostictype = 4 then cast(IsAlloantibody as varchar(4)) else null end IsAlloantibody
	, d.DAYSSINCESTART1STENCOUNTER -112 as TxDaysStart, d.DAYSSINCESTART1STENCOUNTER -15 as TxDaysEnd
	, case --Only for antibody identification
		when DiagnosticType = 4 then d_abOrder.abIdOrder
		else null end AbIdOrder
	, case --Exclude a positive screen with no antibody id
		when DiagnosticType = 3 and LABRESULTS = 'POS' and d_posScreenId.SUBJECTID_RANDOM is not null then 'Ok' 
		when DiagnosticType = 3 and LABRESULTS = 'POS' and d_posScreenId.SUBJECTID_RANDOM is null then 'Bad' 
		else null end PosScreenWithId
	--Check if the previous screen was negative
	, case --Identify antibodies that do not have a prior NEGATIVE (neg or pos but antibody of interest not identified) screen 
		when DiagnosticType = 4 and d_prevScreenNeg.DAYSSINCESTART1STENCOUNTER < d.DAYSSINCESTART1STENCOUNTER then 'Ok'
		when DiagnosticType = 4 then 'Bad'
		else null end PriorTestForAb
into v2.tests
from [dbo].[diagnostics_filtered] d
--Subquery to order the frequency of an antibodies identification
left join (
	select Id, row_number() over(partition by SUBJECTID_RANDOM, labresults order by DAYSSINCESTART1STENCOUNTER) abIdOrder
	from [dbo].[diagnostics_filtered] 
	where diagnostictype = 4
) d_abOrder on d.id = d_abOrder.id
--Subquery to identify positive screens without an antibody identified
left join (
	select distinct SUBJECTID_RANDOM, DAYSSINCESTART1STENCOUNTER
	from [dbo].[diagnostics_filtered] 
	where DiagnosticType = 4
) d_posScreenId on d.subjectid_random = d_posScreenId.subjectid_random and d.DAYSSINCESTART1STENCOUNTER = d_posScreenId.DAYSSINCESTART1STENCOUNTER
--Subquery to check if previous screen was negative
left join (
	select SUBJECTID_RANDOM, min(DAYSSINCESTART1STENCOUNTER) DAYSSINCESTART1STENCOUNTER
	from [dbo].[diagnostics_filtered] 
	where (DiagnosticType = 3 /*screen*/ and LABRESULTS = 'NEG')
	or DiagnosticType = 4 /*ab id*/
	group by SUBJECTID_RANDOM
) d_prevScreenNeg on d.SUBJECTID_RANDOM = d_prevScreenNeg.SUBJECTID_RANDOM and d_prevScreenNeg.DAYSSINCESTART1STENCOUNTER < d.DAYSSINCESTART1STENCOUNTER
--where SUBJECTID_RANDOM = 210000548144
order by d.SUBJECTID_RANDOM, d.DAYSSINCESTART1STENCOUNTER

--------------------------------------------------------------------
--	Creating the events table
--------------------------------------------------------------------
drop table if exists v2.myevents
select *
	, case when IsAlloantibody = 'Yes' and AbIdOrder = 1 and PriorTestForAb = 'Ok' then 'Case' else null end CaseQ
into v2.myevents
from (
	select OriginalTable, EventName, OriginalTableId, SubjectId_Random, EncounterId_Random, DaysSinceStart1stEncounter
		, AbFormDaysStart, AbFormDaysEnd, DIN_Random, DaysDonationToIssue
		, Washed ProductWashed, Irradiated ProductIrradiated, Leukoreduced ProductLeukoreduced, Thawed ProductThawed
		, cast(null as numeric(5,0)) [TxDaysStart], cast(null as numeric(5,0)) [TxDaysEnd], cast(null as varchar(6)) [DiagnosticType]
		, cast(null as varchar(12)) [LABRESULTS], cast(null as varchar(4)) [IsAlloantibody], cast(null as bigint) [AbIdOrder]
		, cast(null as varchar(3)) [PosScreenWithId], cast(null as varchar(3)) [PriorTestForAb]
	from v2.issued
	union
	select OriginalTable, EventName, OriginalTableId, SubjectId_Random, EncounterId_Random, DaysSinceStart1stEncounter
		, null AbFormDaysStart, null AbFormDaysEnd, null DIN_Random, null DaysDonationToIssue
		, null ProductWashed, null ProductIrradiated, null ProductLeukoreduced, null ProductThawed
		, [TxDaysStart], [TxDaysEnd], [DiagnosticType], [LABRESULTS], [IsAlloantibody], [AbIdOrder], [PosScreenWithId], [PriorTestForAb]
	from v2.tests
) t
order by subjectId_random, dayssincestart1stencounter, originaltable desc

--------------------------------------------------------------------
--	Adding to the events table
--------------------------------------------------------------------
--For each RBC, identify negative screen in the 'AbForm' window
drop table if exists #controlNegScreen
select distinct e1.EventName, e1.OriginalTableId
into #controlNegScreen
from (select * from v2.myevents where eventname = 'RBCTx') e1
join (
	select * 
	from v2.myevents 
	where (DiagnosticType = 'Screen' and LABRESULTS = 'NEG')
		or (DiagnosticType = 'AbId' and PosScreenWithId = 'Ok')
) e2 
	on e1.SUBJECTID_RANDOM = e2.SUBJECTID_RANDOM and e2.DAYSSINCESTART1STENCOUNTER >= e1.AbFormDaysStart and e2.DAYSSINCESTART1STENCOUNTER <= e1.AbFormDaysEnd
--where subjectid_random = 210003060142
--order by subjectId_random, dayssincestart1stencounter, originaltable desc

--For each RBC, identify if a new antibody was formed
drop table if exists #lookForNewAb
select distinct e1.EventName, e1.OriginalTableId
into #lookForNewAb
from (select * from v2.myevents where eventname = 'RBCTx') e1
join (
	select * 
	from v2.myevents 
	where AbIdOrder = 1 --Only new antibodies
) e2 
	on e1.SUBJECTID_RANDOM = e2.SUBJECTID_RANDOM and e2.DAYSSINCESTART1STENCOUNTER >= e1.AbFormDaysStart and e2.DAYSSINCESTART1STENCOUNTER <= e1.AbFormDaysEnd
--where subjectid_random = 210003060142
--order by subjectId_random, dayssincestart1stencounter, originaltable desc


--Adding a column to 'myevents'
drop table if exists v2.myevents2
select *
	, case when EventName = 'RBCTx' and TxHasNegControl = 'Ok' and ExcludeForNewAb = 'Ok' then 'Control'
		else null end ControlQ
into v2.myevents2
from (
	select --top 10000
		t.*
		, case --Need negative screen or antibody id
			when t.EventName = 'RBCTx' and c.EventName is not null then 'Ok' 
			when t.EventName = 'RBCTx' and c.EventName is null then 'Bad'
			else null end TxHasNegControl
		, case --No new antibodies
			when t.EventName = 'RBCTx' and l.EventName is not null then 'Bad' 
			when t.EventName = 'RBCTx' and l.EventName is null then 'Ok'
			else null end ExcludeForNewAb
	from v2.myevents t
	--Subquery requiring a negative screen or positive screen with known antibodies. Otherwise, you do not know if the transfusion generated a response.
	left join #controlNegScreen c on c.EventName = t.EventName and c.OriginalTableId = t.OriginalTableId and t.OriginalTable = 'Issued'
	--Subquery removing newly formed antibodies
	left join #lookForNewAb l on l.EventName = t.EventName and l.OriginalTableId = t.OriginalTableId and t.OriginalTable = 'Issued'
) t
order by t.subjectId_random, t.dayssincestart1stencounter, t.originaltable desc

--------------------------------------------------------------------
--	Joining alloimmunizations to transfusions
--------------------------------------------------------------------
drop table if exists v2.abToTx
select e1.OriginalTable OriginalTableAb, e1.OriginalTableId OriginalTableIdAb, e2.OriginalTable OriginalTableRBCTx, e2.OriginalTableId OriginalTableIdRBCTx
into v2.abToTx
from v2.myevents2 e1 --DiagnosticType = AbId
join v2.myevents2 e2 --EventName = RBCTx
	on e1.SUBJECTID_RANDOM = e2.SUBJECTID_RANDOM and e1.TxDaysStart <= e2.DAYSSINCESTART1STENCOUNTER and e1.TxDaysEnd >= e2.DAYSSINCESTART1STENCOUNTER
where e1.CaseQ = 'Case'
and e2.EventName = 'RBCTx'

--How many alloantibodies did the transfusion form?
drop table if exists v2.abToTxGrouped
select OriginalTableRBCTx, OriginalTableIdRBCTx, count(1) NumAbFormedCase
into v2.abToTxGrouped
from v2.abToTx
group by OriginalTableRBCTx, OriginalTableIdRBCTx

--How many transfusions were implicated in the alloimmunization
drop table if exists v2.txToAbGrouped
select OriginalTableAb, OriginalTableIdAb, count(1) NumRBCsCase
into v2.txToAbGrouped
from v2.abToTx
group by OriginalTableAb, OriginalTableIdAb

--Link NumRBCsCase back to the unit -> This does not make sense because a unit may have multiple associated antibodies each with their own number of RBC cases.
--select *
--from v2.txToAbGrouped t
--join v2.abToTx a on a.OriginalTableAb = t.OriginalTableAb and a.OriginalTableIdAb = t.OriginalTableIdAb
--where t.OriginalTableIdAb = 360195

--------------------------------------------------------------------
--	These tables are not combined in the events table
--------------------------------------------------------------------
--3. Subject: Begining with subject id, age, gender, race, ethnicity
drop table if exists v2.encounters
select --top 10 
	ENCOUNTERID_RANDOM, GenderG, Age, Race, Ethnicity, DAYSSINCESTART1STENCOUNTER
into v2.encounters
from [dbo].[encounter_filtered] --join with ENCOUNTERID_RANDOM

--4. ICD: Beginning with primary diagnoses from issued encounters
--Retaining row id, subject id, encounter id, ICD type, ICD code
--WARNING! This table does not have a unique ENCOUNTERID_RANDOM
--drop table if exists v2.icd
--select --top 10 
--	ENCOUNTERID_RANDOM, CodeAttr, Code 
--into v2.icd
--from diagnosis_filtered --join with ENCOUNTERID_RANDOM

--============================================= diagnosis raw
-- Uploaded in two tables due to memory error.

drop table if exists diagnosis_filtered
select distinct e.EncounterId_Random, t.CODE, t.CODEATTR, t.CODETYPE, m.ICDGroup
into diagnosis_filtered
from (select * from v2.myevents2 where EventName = 'RBCTx') e
join (
	select * from [dbo].[diagnosisCodes1]
	union
	select * from [dbo].[diagnosisCodes2]
) t on e.subjectId_random = t.SUBJECTID_RANDOM and t.DAYSSINCESTART1STENCOUNTER <= e.DAYSSINCESTART1STENCOUNTER --All codes prior to encounter
join [dbo].[Dim_ICDMatch] m on m.ICD = t.CODE

drop table if exists v2.icd
select EncounterId_Random, isnull([CAD],0) [CAD], isnull([Cancer],0) [Cancer], isnull([Leukemia],0) [Leukemia], isnull([MDS],0) [MDS]
	, isnull([RA],0) [RA], isnull([SCD],0) [SCD], isnull([SickleTrait],0) [SickleTrait], isnull([SLE],0) [SLE], isnull([Transplant],0) [Transplant]
into v2.icd
from (
	select EncounterId_Random, ICDGroup, 1 Present
	from diagnosis_filtered
	group by EncounterId_Random, ICDGroup
) t
pivot ( 
	max(Present)
	for ICDGroup in ([CAD],[Cancer],[Leukemia],[MDS],[RA],[SCD],[SickleTrait],[SLE],[Transplant])
) t

--------------------------------------------------------------------
--	Joining all tables together -> Views
--------------------------------------------------------------------
--Create final table
drop table if exists v2.myevents3
select e.*, c.AGE, c.GENDERG, c.RACE, c.ETHNICITY
	, a.NumAbFormedCase, t.NumRBCsCase
	, case when a.NumAbFormedCase > 0 then 'Case' else null end CaseRBCTxQ
	, case when a.NumAbFormedCase > 0 then '1' when ControlQ = 'Control' then '0' else null end CaseControl 
	, d.age DonorAge, d.sex DonorSex
	, 
		case 
			when d.ABO_RH is null then 'Unknown'
			when d.ABO_RH = 'A-' then  'A'
			when d.ABO_RH = 'A+' then  'A'
			when d.ABO_RH = 'AB-' then 'AB'
			when d.ABO_RH = 'AB+' then 'AB'
			when d.ABO_RH = 'B-' then  'B'
			when d.ABO_RH = 'B+' then  'B'
			when d.ABO_RH = 'O-' then  'O'
			when d.ABO_RH = 'O+' then  'O'
			when d.ABO_RH = 'U' then 'Unknown'
			else 'Unknown' end DonorABO,
		case 
			when d.ABO_RH is null then 'Unknown'
			when d.ABO_RH = 'A-' then  'Neg'
			when d.ABO_RH = 'A+' then  'Pos'
			when d.ABO_RH = 'AB-' then 'Neg'
			when d.ABO_RH = 'AB+' then 'Pos'
			when d.ABO_RH = 'B-' then  'Neg'
			when d.ABO_RH = 'B+' then  'Pos'
			when d.ABO_RH = 'O-' then  'Neg'
			when d.ABO_RH = 'O+' then  'Pos'
			when d.ABO_RH = 'U' then 'Unknown'
			else 'Unknown' end DonorRh	
	, round(hb_value,1) DonorHb, HEIGHT_FEET*12 + HEIGHT_INCHES DonorHeight, [weight] DonorWeight, transfus DonorTransfuse, bornusa DonorBornUSA, education DonorEdu, PREGNANT DonorPreg, THIRTYDSMOKED DonorSmoke
	, ferritin DonorFerritin, d.DAYS_BTW_CONTACTS DonorDaysLastDonation
	, case 
		when d.sex = GENDERG then 'Same' 
		when (c.genderg = 'M' and d.sex = 'F') or (c.genderg = 'F' and d.sex = 'M') then 'Different' 
		else 'Unknown' end DonorRecipGender
	, case 
		when (c.ETHNICITY = 'Y' and d.ETHNICITY = 'Y') or (c.ETHNICITY = 'N' and d.ETHNICITY = 'N') then 'Same'
		when (c.ETHNICITY = 'Y' and d.ETHNICITY = 'N') or (c.ETHNICITY = 'N' and d.ETHNICITY = 'Y') then 'Different'
		else 'Unknown' end DonorRecipEthnicity
	, d.ETHNICITY DonorEthnicity, d.RACERECODE DonorRace
	, isnull(rbt.ABO,'Unknown') RecipABO, isnull(rbt.Rh,'Unknown') RecipRh
	, [CAD],[Cancer],[Leukemia],[MDS],[RA],[SCD],[SickleTrait],[SLE],[Transplant]
into v2.myevents3
from v2.myevents2 e
left join v2.encounters c on e.encounterid_random = c.encounterid_random 
left join v2.icd i on e.encounterid_random = i.encounterid_random
left join v2.abToTxGrouped a on e.OriginalTableId = a.OriginalTableIdRBCTx and e.OriginalTable = a.OriginalTableRBCTx
left join v2.txToAbGrouped t on e.OriginalTableId = t.OriginalTableIdAb and e.OriginalTable = t.OriginalTableAb
left join donations_filtered d on d.DIN_RANDOM = e.DIN_RANDOM
left join diagnosticsABORh_final rbt on rbt.subjectid_random = e.SUBJECTID_RANDOM
order by subjectId_random, dayssincestart1stencounter, originaltable desc

--Everything
select top 1000 *
from v2.myevents3
order by subjectId_random, dayssincestart1stencounter, originaltable desc

--Case review view
select EventName, SUBJECTID_RANDOM, CaseQ, CaseRBCTxQ, ControlQ
	, DiagnosticType, LABRESULTS
	, DAYSSINCESTART1STENCOUNTER, AbFormDaysStart, AbFormDaysEnd, TxDaysStart, TxDaysEnd
	, IsAlloantibody, AbIdOrder, PosScreenWithId, PriorTestForAb, TxHasNegControl, ExcludeForNewAb
	, NumAbFormedCase, NumRBCsCase
	, DAYSDONATIONTOISSUE, age, GENDERG, race
from v2.myevents3
where SUBJECTID_RANDOM = 211432577129
order by subjectId_random, dayssincestart1stencounter, originaltable desc

--No work, just data
select top 5000 
	EventName, SUBJECTID_RANDOM, CaseQ, CaseRBCTxQ, ControlQ, CaseControl
	, DiagnosticType, LABRESULTS
	--, DAYSSINCESTART1STENCOUNTER, AbFormDaysStart, AbFormDaysEnd, TxDaysStart, TxDaysEnd
	--, IsAlloantibody, AbIdOrder, PosScreenWithId, PriorTestForAb, TxHasNegControl, ExcludeForNewAb
	, NumAbFormedCase, NumRBCsCase
	, DonorAge, DonorSex, DonorABORh, DonorHb, DonorHeight, DonorWeight, DonorTransfuse, DonorBornUSA, DonorEdu, DonorPreg, DonorSmoke, DonorFerritin, DonorDaysLastDonation
	, DAYSDONATIONTOISSUE ProductDays
	, age RecipAge, GENDERG RecipGender, race RecipRace
from v2.myevents3 e
where 1=1 
and SUBJECTID_RANDOM = 211432577129
and (CaseQ is not null or CaseRBCTxQ is not null or ControlQ is not null)
order by subjectId_random, dayssincestart1stencounter, originaltable desc

--Data summary
select top 5000 
	EventName, SUBJECTID_RANDOM, CaseQ, CaseRBCTxQ, ControlQ, CaseControl 
	, DiagnosticType, LABRESULTS
	, NumAbFormedCase, NumRBCsCase
	, DonorAge, DonorSex, DonorABORh, DonorHb, DonorHeight, DonorWeight, DonorTransfuse, DonorBornUSA, DonorEdu, DonorPreg, DonorSmoke, DonorFerritin
	, DonorRecipGender
	, DAYSDONATIONTOISSUE ProductDays
	, age RecipAge, GENDERG RecipGender, race RecipRace
from v2.myevents3 e
where 1=1 
--and SUBJECTID_RANDOM = 211432577129
and (CaseRBCTxQ is not null or ControlQ is not null)
and DIN_RANDOM is not null
order by subjectId_random, dayssincestart1stencounter, originaltable desc
--select * from v2.myevents3

--------------------------------------------------------------------
--	Joining all tables together -> Views
--------------------------------------------------------------------
--DEPRECATED: SEE ALTERNATIVE BELOW
----R export: prematching table. "Table 2"
--drop table if exists v2.R_prematching
--select
--	SUBJECTID_RANDOM, CaseControl 	
--	, DonorAge, DonorSex, DonorABORh, DonorHb, DonorHeight, DonorWeight, DonorTransfuse, DonorBornUSA, DonorEdu, DonorPreg, DonorSmoke, DonorFerritin, DonorDaysLastDonation
--	, DonorRecipGender, DonorRecipEthnicity
--	, DAYSDONATIONTOISSUE ProductDays
--	, age RecipAge, GENDERG RecipGender, e.ETHNICITY RecipEthnicity, race RecipRace, DonorRace/*, CODEATTR RecipCodeAttr, CODE RecipCode*/
--	, [CAD],[Cancer],[Leukemia],[MDS],[RA],[SCD],[SickleTrait],[SLE],[Transplant]
--into v2.R_prematching
--from v2.myevents3 e
--where 1=1 
----and SUBJECTID_RANDOM = 211432577129
--and EventName = 'RBCTx'
--and (CaseRBCTxQ is not null or ControlQ is not null)
--and DIN_RANDOM is not null
--order by subjectId_random, dayssincestart1stencounter, originaltable desc
----select top 100 * from v2.R_prematching
----select CaseControl, count(1) from v2.R_prematching group by CaseControl


--R export: prematching but only patients that have a "case" RBC issued. "Table 4"
drop table if exists v2.R_prematching2
select
	CaseControl 	
	, DonorAge, DonorSex, DonorABORh, DonorHb, DonorHeight, DonorWeight, DonorTransfuse, DonorBornUSA, DonorEdu, DonorPreg, DonorSmoke, DonorFerritin, DonorDaysLastDonation
	, DonorRecipGender, DonorRecipEthnicity, DonorEthnicity
	, DAYSDONATIONTOISSUE ProductDays, ProductIrradiated, ProductLeukoreduced, ProductThawed, ProductWashed
	, age RecipAge, GENDERG RecipGender, e.ETHNICITY RecipEthnicity, race RecipRace, ETHNICITY RecipEthnicity/*, CODEATTR RecipCodeAttr, CODE RecipCode*/
into v2.R_prematching2
from v2.myevents3 e
join (select distinct SUBJECTID_RANDOM from v2.myevents3 where CaseControl = 1) t on e.SUBJECTID_RANDOM = t.SUBJECTID_RANDOM
where 1=1 
--and SUBJECTID_RANDOM = 211432577129
and EventName = 'RBCTx'
and (CaseRBCTxQ is not null or ControlQ is not null)
and DIN_RANDOM is not null
--select top 100 * from v2.R_prematching2
--select CaseControl, count(1) from v2.R_prematching2 group by CaseControl

--Count the number of case/controls for each person with at least one case ("Table 3")
select [Case], [Control], count(1) total
from (
	select isnull([1],0) as [Case], isnull([0],0) as [Control]
	from (
		select
			e.SUBJECTID_RANDOM, CaseControl, count(1) total
		from v2.myevents3 e
		join (select distinct SUBJECTID_RANDOM from v2.myevents3 where CaseControl = 1) t on e.SUBJECTID_RANDOM = t.SUBJECTID_RANDOM
		where 1=1 
		--and SUBJECTID_RANDOM = 211432577129
		and EventName = 'RBCTx'
		and CaseControl is not null
		group by e.SUBJECTID_RANDOM, CaseControl
		--order by SUBJECTID_RANDOM
	) t
	pivot (
		max(total)
		for CaseControl in ([1],[0])
	) t
) t
group by [Case], [Control]
order by total desc

--R export: prematching but only patients that have a single "case" RBC issued. "Table 5"
drop table if exists v2.R_prematching3
select
	e.SUBJECTID_RANDOM, CaseControl 	
	, DonorAge, DonorSex, DonorABORh, DonorHb, DonorHeight, DonorWeight, DonorTransfuse, DonorBornUSA, DonorEdu, DonorPreg, DonorSmoke, DonorFerritin
	, DAYSDONATIONTOISSUE ProductDays
	, age RecipAge, GENDERG RecipGender, e.ETHNICITY RecipEthnicity, race RecipRace/*, CODEATTR RecipCodeAttr, CODE RecipCode*/
into v2.R_prematching3
from v2.myevents3 e
join (
	--For each subject with at least one "Case" RBC transfusion, count the number of "Case"/"Control" transfusions. 
	select subjectid_random, isnull([1],0) as [Case], isnull([0],0) as [Control]
	from (
		select e.SUBJECTID_RANDOM, CaseControl, count(1) total
		from v2.myevents3 e
		join (select distinct SUBJECTID_RANDOM from v2.myevents3 where CaseControl = 1) t --Patients who are cases
			on e.SUBJECTID_RANDOM = t.SUBJECTID_RANDOM
		where 1=1 
		--and SUBJECTID_RANDOM = 211432577129
		and EventName = 'RBCTx' --Events include both "RBCTx" and "Test"
		and CaseControl is not null
		group by e.SUBJECTID_RANDOM, CaseControl
		--order by SUBJECTID_RANDOM
	) t
	pivot (
		max(total)
		for CaseControl in ([1],[0])
	) t
) t on e.SUBJECTID_RANDOM = t.SUBJECTID_RANDOM
where 1=1 
--and SUBJECTID_RANDOM = 211432577129
and EventName = 'RBCTx'
and (CaseRBCTxQ is not null or ControlQ is not null)
and DIN_RANDOM is not null
and [Case] = 1 and [Control] = 0
--select * from v2.R_prematching3
--select avg(RecipAge) from v2.R_prematching3
--select avg(DonorAge) from v2.R_prematching3


/* Many of the patients with a single case do not have donor information (30/105) */
select Case when DonorAge is null then 0 else 1 end LinkedQ, count(1) total
from v2.R_prematching3
group by (Case when DonorAge is null then 0 else 1 end)

--select * from v2.R_prematching3
--select top 1000 * from v2.myevents3 --case = 0, control = 1, null is neither
--select distinct EventName from v2.myevents3 
--select * from v2.R_prematching3

----------------Same as "v2.R_prematching" except with the an additional column designating the patients with a single case.
drop table if exists v2.R_prematching4
select
	e.SUBJECTID_RANDOM
	, e.CaseControl, case when p.SUBJECTID_RANDOM is not null then 1 else 0 end CaseControl1Only
	, e.DonorAge, e.DonorSex, e.DonorABORh, e.DonorHb, e.DonorHeight, e.DonorWeight, e.DonorTransfuse, e.DonorBornUSA, e.DonorEdu, e.DonorPreg, e.DonorSmoke, e.DonorFerritin, e.DonorDaysLastDonation
	, e.DonorRecipGender
	, DAYSDONATIONTOISSUE ProductDays
	, age RecipAge, GENDERG RecipGender, race RecipRace/*, CODEATTR RecipCodeAttr, CODE RecipCode*/
into v2.R_prematching4
from v2.myevents3 e
left join v2.R_prematching3 p on p.subjectid_random = e.subjectid_random
where 1=1 
--and SUBJECTID_RANDOM = 211432577129
and EventName = 'RBCTx'
and (CaseRBCTxQ is not null or ControlQ is not null)
and DIN_RANDOM is not null
--select * from v2.R_prematching4

/*
--Matches Table 2 as expected because this is the same as "v2.R_prematching": 194204 and 3790
select CaseControl, count(1) total
from v2.R_prematching4
group by CaseControl

--Matches Table 5 as expected: cases = 105
select CaseControl1Only, count(1) total
from v2.R_prematching4
group by CaseControl1Only
*/
-------------------------------------------------

drop table if exists #CaseControlCount
select *, cast([Case] as int) + cast([Control] as int) as SumCaseControl
into #CaseControlCount
from (
	select SubjectId_Random, isnull([1],0) as [Case], isnull([0],0) as [Control]
	from (
		select
			e.SUBJECTID_RANDOM, CaseControl, count(1) total
		from v2.myevents3 e
		join (select distinct SUBJECTID_RANDOM from v2.myevents3 where CaseControl = 1) t on e.SUBJECTID_RANDOM = t.SUBJECTID_RANDOM
		where 1=1 
		--and SUBJECTID_RANDOM = 211432577129
		and EventName = 'RBCTx'
		and CaseControl is not null
		group by e.SUBJECTID_RANDOM, CaseControl
		--order by SUBJECTID_RANDOM
	) t
	pivot (
		max(total)
		for CaseControl in ([1],[0])
	) t
) t

--R export: prematching table. "Table 2"
drop table if exists v2.R_prematching
select 
	CaseControl
	, isnull([Case],0) SubjectCases, isnull([Control],0) SubjectControls
	,  isnull([Case],0) + isnull([Control],0) SubjectTotal
	, DonorAge, DonorSex
	, case 
		when DonorRace = 1 then 'W'
		when DonorRace = 2 then 'B'
		when DonorRace = 3 then 'I'
		when DonorRace = 4 then 'A'
		when DonorRace = 5 then 'H'
		when DonorRace is null or DonorRace in (9, 11) then 'Unknown' 
		end DonorRace
	, DonorABO, DonorRh
	, DonorHb, DonorHeight, DonorWeight, DonorTransfuse, DonorBornUSA, 
		DonorEdu, DonorPreg, DonorSmoke, DonorFerritin, DonorDaysLastDonation
	, DAYSDONATIONTOISSUE ProductDays, ProductIrradiated
	, age RecipAge, GENDERG RecipGender, RecipABO, RecipRh
	, e.ETHNICITY RecipEthnicity, race RecipRace/*, CODEATTR RecipCodeAttr, CODE RecipCode*/
	, [CAD],[Cancer],[Leukemia],[MDS],[RA],[SCD],[SickleTrait],[SLE],[Transplant]
	, DonorRecipGender, DonorRecipEthnicity,
		case 
			when (DonorRace = 1 and race = 'W') 
				or (DonorRace = 2 and race = 'B') 
				or (DonorRace = 3 and race = 'I') 
				or (DonorRace = 4 and race = 'A') 
				or (DonorRace = 5 and race = 'H') 
				then 'Same'
			when DonorRace is null or donorRace = 9 or DonorRace = 88 
				or race is null or race = '' or race = '-6' or race='-8' then 'Unknown'
			else 'Different' end DonorRecipRace
	, case 
		when DonorABO = RecipABO and DonorABO != 'Unknown' then 'Same'
		--Checked for 'unknown' matching with 'unknown'
		else 'Different' end DonorRecipABO
	, case
		when DonorRh = RecipRh and DonorRh != 'Unknown' then 'Same'
		else 'Different' end DonorRecipRh
into v2.R_prematching
from v2.myevents3 e
left join #CaseControlCount c on c.SUBJECTID_RANDOM = e.SUBJECTID_RANDOM
where 1=1 
and EventName = 'RBCTx'
and (CaseRBCTxQ is not null or ControlQ is not null)
and DIN_RANDOM is not null

--select count(1) from v2.R_prematching --163,483

select top 10 * from v2.R_prematching
select DonorRAce, count(1) total from v2.R_prematching group by donorrace
select * from v2.R_prematching

select distinct DonorABO, RecipABO, DonorRecipABO from v2.R_prematching order by DonorABO, RecipABO
select distinct DonorRh, RecipRh, DonorRecipRh from v2.R_prematching order by donorRh, RecipRh


select DonorRace, count(1) total from v2.myevents3 group by DonorRace
select Race, count(1) total from v2.myevents3 group by Race

select * from [dbo].[donations]

select DonorRecipRace, RecipRace, DonorRace, count(1) total
from v2.R_prematching 
group by DonorRecipRace, RecipRace, DonorRace
order by DonorRecipRace, RecipRace


select CaseControl, DonorRecipRace, count(1) total
from v2.R_prematching 
group by CaseControl, DonorRecipRace


select CaseControl, DonorRace, RecipRace, count(1) total
from v2.R_prematching 
where DonorRace in (1, 2) and RecipRace in ('W','B')
group by CaseControl, DonorRace, RecipRace