# r69 · Part A feature 3: full data export (backup file + Excel workbook)
import sys,io; sys.path.insert(0,'/home/claude/ld/t'); from h import *
import openpyxl
ok=bad=0
def chk(n,c,extra=''):
    global ok,bad; ok+=bool(c); bad+=(not c); print(('PASS ' if c else 'FAIL ')+n+('' if c else '   '+str(extra)))
def toBackup(pg):
    pg.evaluate("()=>{S.tab='set';S.setSec='sys';render()}"); pg.wait_for_selector('#backupPanel')
def dl(pg,sel):
    with pg.expect_download(timeout=60000) as d: pg.click(sel)
    f=d.value; path=f'/home/claude/ld/t/out_{f.suggested_filename}'; f.save_as(path); pg.wait_for_function("()=>!(S.bk||{}).busy"); pg.wait_for_timeout(200); return f.suggested_filename,path
with sync_playwright() as p:
    br=p.chromium.launch()
    pg=page(br,USERS['sup'],ls={'fake.auditRows':3500}); ready(pg)
    pg.evaluate("()=>{const d=window.__FAKE.DB.docs.find(x=>x.path==='config/settings').doc;d.zzMail={host:'smtp.demo.test',password:'TOPSECRET1',apiKey:'TOPSECRET2',nested:{token:'TOPSECRET3',from:'a@b.c'}}}")
    toBackup(pg)
    chk('Supervisor sees both downloads',pg.query_selector('#bkBtn') and pg.query_selector('#bkXls'))
    pg.evaluate("window.__FAKE.calls.length=0"); name,path=dl(pg,'#bkBtn'); raw=open(path).read(); J=json.loads(raw); T=J['tables']; calls=pg.evaluate("window.__FAKE.calls")
    chk('backup file: valid, format 2, complete',J['app']=='Lead Desk' and J['format']==2 and J['complete'] is True and name.startswith('LeadDesk_Backup_') and name.endswith('.json'),J.get('notes'))
    chk('backup file: every table present',set(T)=={'leads','accounts','contracts','members','docs','audit_log'},list(T))
    chk('backup file: all 1,043 leads with their full record',len(T['leads'])==1043 and all('doc' in r and 'id' in r for r in T['leads']))
    chk('backup file: contracts, users, all settings documents',len(T['contracts'])==1 and len(T['members'])==6 and {d['path'] for d in T['docs']}>={'config/settings','config/permissions','config/pricebook','config/targets','config/references','config/linerules'},[d['path'] for d in T['docs']])
    chk('backup file: whole audit trail (3,500+ entries)',len(T['audit_log'])>=3501,len(T['audit_log']))
    chk('backup file: counts match the database count',all(J['counts'][k]>=J['serverCounts'][k] for k in J['serverCounts']),(J['counts'],J['serverCounts']))
    chk('no password, API key or token anywhere in the file','TOPSECRET' not in raw and 'smtp.demo.test' in raw)
    chk('database is asked for permission first (export_begin)',calls[0]=='rpc:export_begin',calls[:2])
    sel=[c for c in calls[:calls.index('rpc:log_event')] if c.startswith('select:')]
    chk('rows fetched in pages of 1,000 (leads 2 pages, audit 4+)',all(c.endswith(':1000') for c in sel) and sel.count('select:leads:1000')==2 and sel.count('select:audit_log:1000')>=4,sel)
    A=pg.evaluate("window.__FAKE.DB.audit_log.filter(a=>a.action==='exported').map(a=>[a.actor,a.entity_id,a.summary])")
    chk('audit trail: start and finish recorded with who',len(A)==2 and A[0][0]=='sup@demo.test' and 'backup file' in A[0][1] and A[1][1]==name,A)
    chk('progress line ends with Done and the file name',pg.inner_text('#bkProg').startswith('Done: '+name),pg.inner_text('#bkProg')); chk('panel shows the new last-backup date straight away','Last backup file' in pg.inner_text('#backupPanel') and 'today' in pg.inner_text('#backupPanel'))
    chk('"last backup" is updated',pg.evaluate("!!S.settings.lastBackup&&window.__FAKE.DB.docs.find(x=>x.path==='config/settings').doc.lastBackup.at.slice(0,4)==='2026'"))
    name,path=dl(pg,'#bkXls'); wb=openpyxl.load_workbook(path,read_only=True); names=wb.sheetnames
    chk('Excel: one sheet per type of data',all(n in names for n in ['About','Leads','Quotation lines','Meetings','Lead activity','Accounts','Contacts','AMC contracts','Contract lines','Users','Audit trail']) and sum(n.startswith('Settings') for n in names)>=5,names)
    rows=lambda n:list(wb[n].iter_rows(values_only=True))
    L=rows('Leads'); chk('Excel: Leads sheet has a header and 1,043 rows',len(L)==1044 and L[0][-1]=='Deleted',len(L))
    chk('Excel: quotation lines, contract lines and contacts filled',len(rows('Quotation lines'))>=7 and len(rows('Contract lines'))==3 and len(rows('Contacts'))>300,(len(rows('Quotation lines')),len(rows('Contract lines')),len(rows('Contacts'))))
    U=rows('Users'); chk('Excel: Users sheet lists 6 users, no password column',len(U)==7 and not any('pass' in str(c).lower() for c in U[0]),U[0])
    chk('Excel: audit trail sheet filled, newest first',len(rows('Audit trail'))>=3502)
    allx=' '.join(str(c) for n in names for r in rows(n) for c in r if c is not None)
    chk('Excel: no secret in any sheet','TOPSECRET' not in allx)
    chk('Excel export is also in the audit trail',pg.evaluate("window.__FAKE.DB.audit_log.filter(a=>a.action==='exported').length")==4)
    chk('no script errors',not pg.errors,pg.errors[:3])
    # database part missing
    pg=page(br,USERS['sup'],ls={'fake.nosql':['export_begin']}); ready(pg); toBackup(pg); pg.click('#bkBtn'); pg.wait_for_timeout(600)
    chk('SQL file not run yet: clear message, no download','35_full_export.sql' in pg.inner_text('#bkProg'),pg.inner_text('#bkProg'))
    # other roles
    for k in ('lm','mg','sales','amc'):
        pg=page(br,USERS[k]); ready(pg)
        chk(f'{k}: no Backup panel',pg.evaluate("()=>{try{S.tab='set';render()}catch(e){}return !document.querySelector('#backupPanel')&&!document.querySelector('#bkBtn')}"))
        pg.evaluate("()=>fullExport('backup')"); pg.wait_for_timeout(300); chk(f'{k}: export refused by the app',"can't export" in pg.inner_text('#toastHost'))
        r=pg.evaluate("async()=>{const o=can;window.__can0=o;const{error}=await window.__sb.rpc('export_begin',{p_kind:'backup'});return error&&error.code}")
        chk(f'{k}: export refused by the database too',r=='42501',r)
    br.close()
print(f'\n{ok} passed, {bad} failed'); sys.exit(1 if bad else 0)
