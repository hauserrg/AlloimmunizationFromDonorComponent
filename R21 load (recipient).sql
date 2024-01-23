/*
Steps:
1. Load tables from Wizard: diagnostics (REDS), issuedTxProducts (REDS), Dim_ProductType (Westat/Rebecca), Dim_IsAlloantibody (Jeanne)
2. Diagnostics loads fine.
3. IssuedTxProducts has data type errors. (Change empty string to null.)
4. Filtered IssuedTxProducts to RBC only.
-Some products codes do not have a map (n=172)
5. Filter diagnostics to patients with RBC transfusion and (3 AbID-Screen; 4 AbID-RBC; not 5 AbID-Eluate). Map the antibodies to determine if they are allo- or not.
6. Filtered encounters to patients with RBC transfusion.

Outputs: [dbo].[diagnostics_filtered], [dbo].[issuedTxProducts_filtered], [dbo].[encounter_filtered]. 
The Dim_* tables are not needed after this script.
*/

--Loaded table with Wizard:
/*
drop table if exists Diagnostics
create table Diagnostics
(
	encounterid_random varchar(12),
	subjectid_random varchar(12),
	dayssincestart1stencounter numeric(4,0), 
	diagnostictype numeric(2,0),
	resultedtime varchar(5),
	drawtime varchar(5),
	screendatey numeric(4,0), 
	screendatem numeric(2,0), 
	labvalue numeric(10,3), 
	labunit varchar(13),
	labresults varchar(12),
	dayssincestartencounter numeric(6)
)

--Antibodies are case sensitive
ALTER TABLE [diagnostics] ALTER COLUMN LabResults VARCHAR(12) COLLATE SQL_Latin1_General_CP1_CS_AS

*/
--Table should use " as a text qualifier
use R21

--============================================= Diagnostics raw
EXEC sp_rename 'dbo.diagnostics_pud_g', 'diagnostics';

--============================================= IssuedTxProducts raw
update g set daysdonationtoissue = null from [dbo].[issuedtxproducts_pud_g] g where daysdonationtoissue = ''
update g set [DAYSSINCESTART1STENCOUNTER] = null from [dbo].[issuedtxproducts_pud_g] g where [DAYSSINCESTART1STENCOUNTER] = ''
update g set [DAYSSINCESTARTENCOUNTER] = null from [dbo].[issuedtxproducts_pud_g] g where [DAYSSINCESTARTENCOUNTER] = ''

drop table if exists issuedTxProducts 
create table issuedTxProducts 
(
	[ENCOUNTERID_RANDOM] varchar(12),
	[SUBJECTID_RANDOM] varchar(12),
	[DAYSSINCESTART1STENCOUNTER] numeric(4,0),
	[DIN_RANDOM] varchar(12),
	[PRODUCTCODE] varchar(5),
	[DIVISIONCODE] varchar(3),
	[DIN_PK_RANDOM] varchar(12),
	[DINPOOLEDLINKFLAG] varchar(3),
	[ISSUETIME] varchar(5),
	[DAYSDONATIONTOISSUE] numeric(4,0),
	[ISSUELOC] numeric(3,0),
	[DAYSSINCESTARTENCOUNTER] numeric(3,0)
)

insert into issuedTxProducts
select *
from [dbo].[issuedtxproducts_pud_g]

drop table [dbo].[issuedtxproducts_pud_g]
--============================================= IssuedTxProducts FILTERED
--select producttype, count(1) total
--from [dbo].[Dim_ProductType]
--group by producttype

--n=172
--select productcode from [dbo].[issuedTxProducts]
--except 
--select productcode from [dbo].[Dim_ProductType]

drop table if exists [dbo].[issuedTxProducts_filtered]
CREATE TABLE [dbo].[issuedTxProducts_filtered](
	Id int identity(1,1), primary key (Id),
	[ENCOUNTERID_RANDOM] [varchar](12) NULL,
	[SUBJECTID_RANDOM] [varchar](12) NULL,
	[DAYSSINCESTART1STENCOUNTER] [numeric](4, 0) NULL,
	[DIN_RANDOM] [varchar](12) NULL,
	[PRODUCTCODE] [varchar](5) NULL,
	[DIVISIONCODE] [varchar](3) NULL,
	[DIN_PK_RANDOM] [varchar](12) NULL,
	[DINPOOLEDLINKFLAG] [varchar](3) NULL,
	[ISSUETIME] [varchar](5) NULL,
	[DAYSDONATIONTOISSUE] [numeric](4, 0) NULL,
	[ISSUELOC] [numeric](3, 0) NULL,
	[DAYSSINCESTARTENCOUNTER] [numeric](3, 0) NULL
) 

insert into [dbo].[issuedTxProducts_filtered]
select i.*
from [dbo].[issuedTxProducts] i
join [dbo].[Dim_ProductType] d on i.productcode = d.ProductCode
where d.producttype = 'RBC' 

--reduces rows by 50%
--select count(1 ) from [dbo].[issuedTxProducts_filtered]
--select count(1 ) from [dbo].[issuedTxProducts]

--============================================= Diagnostics FILTERED
--Add Id and limit to labs of interest
drop table if exists [dbo].[diagnostics_filtered]
CREATE TABLE [dbo].[diagnostics_filtered](
	[Id] int identity(1,1), primary key(Id),
	[ENCOUNTERID_RANDOM] [varchar](12) NULL,
	[SUBJECTID_RANDOM] [varchar](12) NULL,
	[DAYSSINCESTART1STENCOUNTER] [numeric](4, 0) NULL,
	[DIAGNOSTICTYPE] [numeric](2, 0) NULL,
	[RESULTEDTIME] [varchar](5) NULL,
	[DRAWTIME] [varchar](5) NULL,
	[SCREENDATEY] [numeric](4, 0) NULL,
	[SCREENDATEM] [numeric](2, 0) NULL,
	[LABVALUE] [numeric](10, 3) NULL,
	[LABUNIT] [varchar](13) NULL,
	[LABRESULTS] [varchar](12) COLLATE SQL_Latin1_General_CP1_CS_AS NULL, 
	[DAYSSINCESTARTENCOUNTER] [numeric](6, 0) NULL,
	[IsAlloantibody] varchar(3) NULL
)

--set anti-D to not an alloantibody
update t
set IsAlloantibody = 'No'
--select *
from Dim_IsAlloantibody t
where AbID_RBC = 'Anti-D'

--n=467 233
insert into [dbo].[diagnostics_filtered]
select d.*, a.IsAlloantibody /*Yes or No*/
from [dbo].[diagnostics] d
join (
	select distinct subjectid_random 
	from [dbo].[issuedTxProducts_filtered]
) i on d.subjectid_random = i.subjectid_random --only from those transfused RBCs
left join [dbo].[Dim_IsAlloantibody] a on a.abid_rbc = d.LABRESULTS
where diagnostictype in (3,4)

--Check that all labresults in (diagnostictype = 4) have a map. They all have a map.
declare @noMap int = (select count(1) from [dbo].[diagnostics_filtered] where IsAlloantibody is null)
if (@noMap > 0) begin throw 60000, 'Review the antibody map', 1 end

--Check for duplicate antibodies introduced by the join to Dim_IsAlloantibody
declare @diag34 int = (
	select count(1)
	from [dbo].[diagnostics] d
	join (
		select distinct subjectid_random 
		from [dbo].[issuedTxProducts_filtered]
	) i on d.subjectid_random = i.subjectid_random --only from those transfused RBCs
	--NO JOIN HERE
	where diagnostictype in (3,4)
)
declare @diagFiltered int = (select count(1) from diagnostics_filtered)
if (@diagFiltered != @diag34 ) begin throw 60000, 'Duplicate antibodies', 1 end

--Alloantibodies only (n=14 056, n=16 601 with anti-D)
drop table if exists diagnostics_filtered_IsAlloantibody
select *
into diagnostics_filtered_IsAlloantibody
from diagnostics_filtered
where IsAlloantibody = 'Yes'

--Remove diagnostics table because it is large
drop table diagnostics

/* 3 = screen (POS, NEG, ...), 4 = antibody (many) 
select [DIAGNOSTICTYPE], LabResults, count(1) total
from [dbo].[diagnostics_filtered]
group by [DIAGNOSTICTYPE], LABRESULTS
order by diagnostictype, count(1) desc
*/

--============================================= Encounters raw
--drop table [dbo].[encounterdemographic_g]
--select * from [dbo].[encounterdemographic_g]

--select max(len([ENCOUNTERID_RANDOM])) [ENCOUNTERID_RANDOM], --12
--	max(len([GENDERG])) [GENDERG], --2
--	max(len([SUBJECTID_RANDOM])) [SUBJECTID_RANDOM], --12
--	max(len([POPCAT])) [POPCAT], --3
--	max(len([ENCOUNTERTYPE])) [ENCOUNTERTYPE], --1
--	max(len([AGE])) [AGE], --2
--	max(len([ADMISSIONDATEM])) [ADMISSIONDATEM], --2
--	max(len([ADMISSIONDATEY])) [ADMISSIONDATEY], --4
--	max(len([ADMISSIONTIME])) [ADMISSIONTIME], --5
--	max(len([DAYSSINCESTART1STENCOUNTER])) [DAYSSINCESTART1STENCOUNTER], --4
--	max(len([DISCHARGEORDEATHDATEM])) [DISCHARGEORDEATHDATEM], --2
--	max(len([DISCHARGEORDEATHDATEY])) [DISCHARGEORDEATHDATEY], --4
--	max(len([DAYSTOENCOUNTERENDDATE])) [DAYSTOENCOUNTERENDDATE], --5
--	max(len([DISCHARGETIME])) [DISCHARGETIME], --5
--	max(len([VENTILATORNEEDED])) [VENTILATORNEEDED], --1
--	max(len([VENTILATORDAYS])) [VENTILATORDAYS], --5
--	max(len([VENTILATORFREEDAYS])) [VENTILATORFREEDAYS], --6
--	max(len([ICU_LOS])) [ICU_LOS], --5
--	max(len([ICUFREEDAYS])) [ICUFREEDAYS], --5
--	max(len([MORTALITY])) [MORTALITY], --1
--	max(len([RACE])) [RACE], --2
--	max(len([ETHNICITY])) [ETHNICITY] --2
--from [dbo].[encounterdemographic_g]

--select top 100 * from [dbo].[encounterdemographic_g]

drop table if exists [dbo].[encounter]
CREATE TABLE [dbo].[encounter](
	[ENCOUNTERID_RANDOM] [varchar](12) NULL,
	[GENDERG] [varchar](2) NULL,
	[SUBJECTID_RANDOM] [varchar](12) NULL,
	[POPCAT] [varchar](3) NULL,
	[ENCOUNTERTYPE] [varchar](1) NULL,
	[AGE] int NULL,
	[ADMISSIONDATEM] int NULL,
	[ADMISSIONDATEY] int NULL,
	[ADMISSIONTIME] [varchar](5) NULL,
	[DAYSSINCESTART1STENCOUNTER] int NULL,
	[DISCHARGEORDEATHDATEM] int NULL,
	[DISCHARGEORDEATHDATEY] int NULL,
	[DAYSTOENCOUNTERENDDATE] int NULL,
	[DISCHARGETIME] [varchar](5) NULL,
	[VENTILATORNEEDED] [varchar](1) NULL,
	[VENTILATORDAYS] [varchar](5) NULL,
	[VENTILATORFREEDAYS] [varchar](6) NULL,
	[ICU_LOS] [varchar](5) NULL,
	[ICUFREEDAYS] [varchar](5) NULL,
	[MORTALITY] int NULL,
	[RACE] [varchar](2) NULL,
	[ETHNICITY] [varchar](2) NULL
)

insert into [dbo].[encounter]
select *
from [dbo].[encounterdemographic_g]

--============================================= Encounters FILTERED
drop table if exists [dbo].[encounter_filtered]
CREATE TABLE [dbo].[encounter_filtered](
	[ENCOUNTERID_RANDOM] [varchar](12) NOT NULL, primary key(encounterid_random),
	[GENDERG] [varchar](2) NULL,
	[SUBJECTID_RANDOM] [varchar](12) NULL,
	[POPCAT] [varchar](3) NULL,
	[ENCOUNTERTYPE] [varchar](1) NULL,
	[AGE] [int] NULL,
	[ADMISSIONDATEM] [int] NULL,
	[ADMISSIONDATEY] [int] NULL,
	[ADMISSIONTIME] [varchar](5) NULL,
	[DAYSSINCESTART1STENCOUNTER] [int] NULL,
	[DISCHARGEORDEATHDATEM] [int] NULL,
	[DISCHARGEORDEATHDATEY] [int] NULL,
	[DAYSTOENCOUNTERENDDATE] [int] NULL,
	[DISCHARGETIME] [varchar](5) NULL,
	[VENTILATORNEEDED] [varchar](1) NULL,
	[VENTILATORDAYS] [varchar](5) NULL,
	[VENTILATORFREEDAYS] [varchar](6) NULL,
	[ICU_LOS] [varchar](5) NULL,
	[ICUFREEDAYS] [varchar](5) NULL,
	[MORTALITY] [int] NULL,
	[RACE] [varchar](2) NULL,
	[ETHNICITY] [varchar](2) NULL
) 

insert into [dbo].[encounter_filtered]
select e.[ENCOUNTERID_RANDOM], e.[GENDERG], e.[SUBJECTID_RANDOM], [POPCAT], [ENCOUNTERTYPE], [AGE], [ADMISSIONDATEM], [ADMISSIONDATEY], [ADMISSIONTIME], [DAYSSINCESTART1STENCOUNTER], [DISCHARGEORDEATHDATEM], [DISCHARGEORDEATHDATEY], [DAYSTOENCOUNTERENDDATE], [DISCHARGETIME], [VENTILATORNEEDED], [VENTILATORDAYS], [VENTILATORFREEDAYS], [ICU_LOS], [ICUFREEDAYS], [MORTALITY], [RACE], [ETHNICITY]
from (
	select *,ROW_NUMBER() over(partition by encounterid_random order by [DAYSSINCESTART1STENCOUNTER] DESC) rn
	from [dbo].[encounter]
) e
join (
	select distinct subjectid_random 
	from [dbo].[issuedTxProducts_filtered]
) i on e.subjectid_random = i.subjectid_random --only from those transfused RBCs
where rn = 1

drop table [dbo].[encounterdemographic_g]

--============================================= Events table
--select top 10 * from diagnostics_filtered
--select top 10 * from issuedTxProducts_filtered
--n=1014482
drop table if exists events_all
select *, rank() over(partition by subjectid_random order by DAYSSINCESTART1STENCOUNTER) ItemRank
into events_all
from (
	select subjectid_random, DAYSSINCESTART1STENCOUNTER, cast(DiagnosticType as varchar(10)) Event1, LabResults Event2, cast(IsAlloantibody as varchar(4)) Event3, 'Diag' Origin, Id from diagnostics_filtered union all
	select subjectid_random, DAYSSINCESTART1STENCOUNTER, 'RBCTx' Event1, DIN_RANDOM collate SQL_Latin1_General_CP1_CS_AS as Event2, cast(DAYSDONATIONTOISSUE as varchar(4)) as Event3, 'Issued' Origin, Id from issuedTxProducts_filtered
) t
order by SUBJECTID_RANDOM, DAYSSINCESTART1STENCOUNTER

drop table if exists events_all_demographics
select subjectid_random, DAYSSINCESTART1STENCOUNTER, Event1, Event2, Event3, Origin, Id, ItemRank, Age, Gender, Race, Ethnicity
into events_all_demographics
from (
	select e.*
		--choose the age of the closest encounter relative to the event
		, ef.AGE Age, GenderG Gender, race Race, ETHNICITY Ethnicity, ROW_NUMBER() over(partition by Origin, e.id order by abs(e.dayssincestart1stencounter - ef.dayssincestart1stencounter) ) rn
	from events_all e
	left join encounter_filtered ef on ef.SUBJECTID_RANDOM = e.subjectid_random
	--Debug only: where e.subjectid_random = 211450517148
) t
where rn = 1
--Debug only: order by ItemRank 

--Debug only: select * from encounter_filtered where SUBJECTID_RANDOM = 211450517148 order by DAYSSINCESTART1STENCOUNTER
--Debug only: select * from events_all where SUBJECTID_RANDOM = 211450517148 order by ItemRank

declare @noAge int = (select count(1) from events_all)
declare @age int = (select count(1) from events_all_age)
if (@noAge != @age) begin throw 60000, 'The age map is not 1:1. Investigate.', 1 end

/* Manual review: 
select count(1) from events_all_demographics
select top 1000 * from events_all_demographics
select * from events_all_demographics where SUBJECTID_RANDOM = 210027793111 order by DAYSSINCESTART1STENCOUNTER
select * from events_all_demographics where SUBJECTID_RANDOM = 210014246115 order by DAYSSINCESTART1STENCOUNTER
*/

----------------------------------------- Loading diagnostics (12/11/2023)
drop table if exists diagnosticsABORh
create table diagnosticsABORh
(
	subjectid_random varchar(12),
	diagnostictype numeric(2,0),
	labresults varchar(12),
)

--insert the data you need into a type defined table
insert into diagnosticsABORh
select subjectid_random, diagnostictype, labresults
from [dbo].[diagnostics_pud_g]
where diagnostictype in (1,2)

--drop table [dbo].[diagnostics_pud_g]

--Stopped here
--QC
select diagnosticType, labresults, count(1) total
from diagnosticsABORh
group by diagnosticType, labresults
order by diagnosticType, count(1) desc

--delete or map?
drop table if exists diagnosticsABORh_map1
create table diagnosticsABORh_map1
(
	subjectid_random varchar(12),
	diagnostictype numeric(2,0),
	diagnostictypeMapped varchar(20),
	labresults varchar(12),
	labresultsMapped varchar(12),
)

insert into diagnosticsABORh_map1
select subjectid_random, diagnostictype,
	case when diagnostictype = 1 then 'ABO' when diagnostictype=2 then 'Rh' else null end diagnostictypeMapped
	, labresults, 
		case 
			when labresults is null then 'Unknown'
			when labresults = 'A' then  'A'
			when labresults = 'AB' then 'AB'
			when labresults = 'B' then  'B'
			when labresults = 'O' then  'O'
			when labresults = 'POS' then 'Pos'
			when labresults = 'NEG' then 'Neg'
			else 'Unknown' end labresultsMapped
from diagnosticsABORh
where labresults in ('A','AB','B','O','POS','NEG')

select * from diagnosticsABORh_map1

drop table if exists diagnosticsABORh_final
create table diagnosticsABORh_final
(
	subjectid_random varchar(12), primary key(subjectid_random),
	ABO varchar(12) not null,
	Rh varchar(12) not null,
)

-- chose a blood type for each subject
insert into diagnosticsABORh_final
select subjectid_random, isnull(ABO, 'Unknown') ABO, isnull(Rh, 'Unknown') Rh
from (
	select subjectid_random, diagnostictype, labresults
	from (
		--Run this first to see if it makes sense
		select subjectid_random
			, diagnostictypeMapped diagnostictype
			, labresultsMapped labresults, count(1) total
			, ROW_NUMBER() over(partition by subjectid_random, diagnostictypeMapped order by count(1) desc) rn
		from diagnosticsABORh_map1
		--debug only: where subjectid_random = (select top 1 subjectid_random from diagnosticsABORh)
		group by subjectid_random, diagnostictypeMapped, labresultsMapped
	) t
	where rn = 1
) t
pivot (
	max(labresults)
	for diagnostictype in ([ABO],[Rh])
) t
