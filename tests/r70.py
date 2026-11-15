# r70 · Part A feature 5: two-step sign-in (MFA)
import sys; sys.path.insert(0,'/home/claude/ld/t'); from h import *
ok=bad=0
def chk(n,c,extra=''):
    global ok,bad; ok+=bool(c); bad+=(not c); print(('PASS ' if c else 'FAIL ')+n+('' if c else '   '+str(extra)))
F=lambda *emails:{e:[{'id':'f-'+e[:3],'status':'verified','factor_type':'totp','friendly_name':'Lead Desk','created_at':'2026-11-10T08:00:00Z'}] for e in emails}
def toPanel(pg): pg.evaluate("()=>{S.tab='set';S.setSec='people';render()}"); pg.wait_for_selector('#mfaPanel'); pg.wait_for_function("()=>!!S.mfaUsers"); pg.wait_for_timeout(150)
aud=lambda pg,a: pg.evaluate("a=>window.__FAKE.DB.audit_log.filter(x=>x.action===a).map(x=>[x.actor,x.entity_id,x.summary])",a)
booted=lambda pg: pg.evaluate("typeof S!=='undefined'&&!!S.leads&&S.leads.length")
with sync_playwright() as p:
    br=p.chromium.launch()
    # 1. Supervisor, rule off, own authenticator not set up
    pg=page(br,USERS['sup']); ready(pg); chk('rule off: sign-in is unchanged, app opens',booted(pg)==1043)
    toPanel(pg); chk('Supervisor sees the Two-step sign-in panel under Users',pg.query_selector('#mfaAll') and len(pg.query_selector_all('[data-mfr]'))==5 and len(pg.query_selector_all('[data-mfu]'))==6)
    pg.select_option('#mfaAll','required'); pg.wait_for_timeout(150); pg.click('#mfaSave'); pg.wait_for_function("()=>S.mfaNote"); 
    chk('lock-out protection: cannot require it before own set-up','own account first' in pg.inner_text('#mfaMsg') and pg.evaluate("S.settings.mfa.mode")=='off',pg.inner_text('#mfaMsg'))
    pg.screenshot(path='shots/mfa_lockout_1440.png')
    pg.click('#mfaMine'); pg.wait_for_selector('.mfas img')
    pg.wait_for_function("()=>{const i=document.querySelector('.mfas img');return i&&i.complete}"); chk('set-up shows a QR picture that really loads, and the key to type',pg.evaluate("document.querySelector('.mfas img').naturalWidth")>0 and 'JBSWY3DP' in pg.evaluate("document.querySelector('#mfkey').textContent") and '<svg' not in pg.inner_text('.mfas'))
    pg.fill('#mfc','111111'); pg.click('#mfok'); pg.wait_for_timeout(200); chk('wrong code is refused',"not right" in pg.inner_text('#mfm') and pg.query_selector('.mfas'))
    pg.fill('#mfc','12'); pg.click('#mfok'); pg.wait_for_timeout(100); chk('short code is refused','6 digits' in pg.inner_text('#mfm'))
    pg.fill('#mfc','123456'); pg.click('#mfok'); pg.wait_for_selector('.mfas',state='detached'); pg.wait_for_function("()=>S.mfaMe&&S.mfaMe.enrolled"); pg.wait_for_timeout(200)
    chk('right code switches it on; recorded in the audit trail',aud(pg,'mfa_enabled')==[['sup@demo.test','sup@demo.test','Switched two-step sign-in on (authenticator app)']],aud(pg,'mfa_enabled'))
    chk('panel now says own two-step is on',"Your own two-step sign-in is on" in pg.inner_text('#mfaPanel'))
    pg.select_option('#mfaAll','required'); pg.wait_for_timeout(100); pg.select_option('[data-mfr="amc"]','optional'); pg.wait_for_timeout(100); pg.select_option('[data-mfu="mg@demo.test"]','off'); pg.wait_for_timeout(100)
    pg.click('#mfaSave'); pg.wait_for_function("()=>S.mfaNote&&S.mfaNote.lvl==='ok'")
    pol=pg.evaluate("window.__FAKE.DB.docs.find(x=>x.path==='config/settings').doc.mfa")
    chk('rule saved: everyone required, AMC optional, one person off',pol=={'mode':'required','roles':{'amc':'optional'},'users':{'mg@demo.test':'off'}},pol)
    chk('rule change recorded in the audit trail',len(aud(pg,'mfa_policy'))==1 and aud(pg,'mfa_policy')[0][0]=='sup@demo.test')
    chk('people who will be asked are flagged',pg.inner_text('#mfaPanel').count('set-up at next sign-in')==3,pg.inner_text('#mfaPanel').count('set-up at next'))
    pg.evaluate("async()=>{await S.db.doc('config/settings').update({mfa:{mode:'off'},weeklyTarget:S.settings.weeklyTarget})}")
    chk('an ordinary settings save cannot change the rule',pg.evaluate("window.__FAKE.DB.docs.find(x=>x.path==='config/settings').doc.mfa.mode")=='required')
    chk('no script errors (supervisor)',not pg.errors,pg.errors[:3])
    REQ={'mode':'required','roles':{'amc':'optional'},'users':{'mg@demo.test':'off'}}
    # 2. Required, not set up: taken through set-up, no data before it
    pg=page(br,USERS['sales'],ls={'fake.mfa':REQ}); ready(pg)
    chk('required + not set up: set-up screen at sign-in, app not opened',pg.query_selector('.mfas img') is not None and not booted(pg) and pg.evaluate("document.getElementById('tabs').hidden"))
    calls=pg.evaluate("window.__FAKE.calls"); chk('nothing is read from the database before set-up (not even the saved copy)',not any(c.startswith('select:') for c in calls),calls)
    chk('only way out is Sign out',pg.inner_text('.mfas #mfx')=='Sign out' and 'requires two-step' in pg.inner_text('.mfas'))
    pg.keyboard.press('Escape'); pg.wait_for_timeout(100); chk('Escape does not skip it',pg.query_selector('.mfas') is not None)
    pg.fill('#mfc','123456'); pg.click('#mfok'); pg.wait_for_function("typeof S!=='undefined'&&S.leads&&S.leads.length>0",timeout=15000)
    chk('after set-up the app opens with the same leads as before',booted(pg)==95,booted(pg)); chk('set-up recorded for that user',aud(pg,'mfa_enabled')[0][0]=='sales@demo.test')
    # 3. Set up, new session: asked for the code
    pg=page(br,USERS['sales'],ls={'fake.mfa':REQ,'fake.factors':F('sales@demo.test')}); ready(pg)
    chk('next sign-in: code screen, no QR, app not opened',pg.query_selector('.mfas #mfc') is not None and not pg.query_selector('.mfas img') and not booted(pg))
    pg.fill('#mfc','000000'); pg.click('#mfok'); pg.wait_for_timeout(200); chk('wrong code: still locked',not booted(pg) and 'not right' in pg.inner_text('#mfm'))
    pg.fill('#mfc','123456'); pg.keyboard.press('Enter'); pg.wait_for_function("typeof S!=='undefined'&&S.leads&&S.leads.length>0",timeout=15000); chk('right code (Enter key): app opens',booted(pg)==95)
    pg.click('.acctm summary'); pg.click('#mfaMenu'); pg.wait_for_selector('.mfas'); pg.wait_for_function("()=>/Supervisor requires/.test(document.querySelector('.mfas').innerText)")
    chk('required: the user cannot switch it off',not pg.query_selector('.mfas #mfok') and 'Only a Supervisor can reset' in pg.inner_text('.mfas')); pg.click('.mfas #mfx')
    # 4. Overrides
    pg=page(br,USERS['mg'],ls={'fake.mfa':REQ}); ready(pg); chk("person set to Off: not asked, app opens",booted(pg)==1043 and not pg.query_selector('.mfas'))
    pg=page(br,USERS['amc'],ls={'fake.mfa':REQ}); ready(pg); chk("role set to Optional: not forced",booted(pg)>0 and not pg.query_selector('.mfas'))
    pg.click('.acctm summary'); pg.click('#mfaMenu'); pg.wait_for_selector('.mfas #mfok'); chk('optional: user can set it up from the account menu',pg.inner_text('.mfas #mfok')=='Set up now')
    pg.click('#mfok'); pg.wait_for_selector('.mfas img'); pg.fill('#mfc','123456'); pg.click('#mfok'); pg.wait_for_selector('.mfas',state='detached')
    pg.click('.acctm summary') if not pg.is_visible('#mfaMenu') else None; pg.click('#mfaMenu'); pg.wait_for_selector('.mfas #mfok'); chk('optional: user can switch it off again',pg.inner_text('.mfas #mfok')=='Switch off')
    pg.click('#mfok'); chk('switching off asks to confirm',pg.inner_text('.mfas #mfok')=='Confirm: switch off' and len(pg.evaluate("window.__FAKE.FACTORS()['amc@demo.test']"))==1)
    pg.click('#mfok'); pg.wait_for_selector('.mfas',state='detached'); chk('switched off and recorded',not pg.evaluate("(window.__FAKE.FACTORS()['amc@demo.test']||[]).length") and len(aud(pg,'mfa_disabled'))==1)
    pg=page(br,USERS['lm'],ls={'fake.mfa':{'mode':'off','roles':{},'users':{}}}); ready(pg); pg.click('.acctm summary'); pg.click('#mfaMenu'); pg.wait_for_function("()=>/not switched it on/.test((document.querySelector('.mfas')||{}).innerText||'')")
    chk('rule off: no set-up offered',not pg.query_selector('.mfas #mfok')); pg.click('.mfas #mfx')
    # 5. Reset by the Supervisor
    pg=page(br,USERS['sup'],aal='aal2',ls={'fake.mfa':REQ,'fake.factors':F('sup@demo.test','sales@demo.test')}); ready(pg); toPanel(pg)
    chk('Users list shows who has it on',pg.inner_text('#mfaPanel').count('Reset two-step')>=2 and pg.query_selector('[data-mfreset="sales@demo.test"]') and not pg.query_selector('[data-mfreset="lm@demo.test"]'))
    for w,h in ((1440,900),):
        pg.screenshot(path='shots/mfa_panel_1440.png')
    pg.click('[data-mfreset="sales@demo.test"]'); chk('reset asks to confirm',pg.inner_text('[data-mfreset="sales@demo.test"]')=='Confirm reset' and len(pg.evaluate("window.__FAKE.FACTORS()['sales@demo.test']"))==1)
    pg.click('[data-mfreset="sales@demo.test"]'); pg.wait_for_function("()=>S.mfaNote"); pg.wait_for_function("()=>!!S.mfaUsers")
    chk('reset removes the authenticator and is recorded',not pg.evaluate("(window.__FAKE.FACTORS()['sales@demo.test']||[]).length") and aud(pg,'mfa_reset')[0][:2]==['sup@demo.test','sales@demo.test'],aud(pg,'mfa_reset'))
    chk('after reset the person is flagged to set up again',not pg.query_selector('[data-mfreset="sales@demo.test"]'))
    pg.evaluate("()=>{S.tab='audit';render()}"); pg.wait_for_timeout(600); chk('audit trail page shows the new entries with readable labels','Two-step reset' in pg.inner_text('#main'),pg.inner_text('#main')[:300])
    # 6. Supervisor with authenticator must enter the code before anything, incl. the rule
    pg=page(br,USERS['sup'],ls={'fake.mfa':REQ,'fake.factors':F('sup@demo.test')}); ready(pg); chk('Supervisor is asked for the code too',pg.query_selector('.mfas #mfc') is not None and not booted(pg))
    r=pg.evaluate("async()=>{const{error}=await window.__sb.rpc('set_mfa_policy',{p:{mode:'off'}});return error&&error.code}"); chk('…and cannot change the rule before the code',r=='42501',r)
    # 7. Other roles
    for k in ('lm','mg','sales','amc'):
        pg=page(br,USERS[k]); ready(pg)
        chk(f'{k}: no Two-step panel',pg.evaluate("()=>{try{S.tab='set';S.setSec='people';render()}catch(e){}return !document.querySelector('#mfaPanel')}"))
        r=pg.evaluate("async()=>{const{error}=await window.__sb.rpc('set_mfa_policy',{p:{mode:'off'}});const r2=await window.__mfa.reset('sup@demo.test');return [error&&error.code,!!r2.error]}"); chk(f'{k}: cannot change the rule or reset anyone',r==['42501',True],r)
    # 8. SQL 36 not run yet: everything works as before
    pg=page(br,USERS['sup'],ls={'fake.nosql':['mfa_state','mfa_users','set_mfa_policy','mfa_log']}); ready(pg); chk('database part not installed: sign-in unchanged',booted(pg)==1043)
    pg.evaluate("()=>{S.tab='set';S.setSec='people';render()}"); pg.wait_for_function("()=>!!S.mfaUsers"); pg.wait_for_timeout(200); chk('…and the panel says which file to run','36_mfa.sql' in pg.inner_text('#mfaPanel'))
    # 9. Supabase MFA switched off in the project
    pg=page(br,USERS['sales'],ls={'fake.mfa':REQ,'fake.mfaDisabled':True}); ready(pg); pg.wait_for_function("()=>/Supabase/.test((document.querySelector('.mfas')||{}).innerText||'')"); chk('TOTP not enabled in Supabase: clear message, Sign out available',pg.query_selector('.mfas #mfx') is not None)
    # 10. phone and tablet widths
    for w in (320,390,768,1024,1440):
        pg=page(br,USERS['sales'],w=w,h=780,ls={'fake.mfa':REQ}); ready(pg); pg.wait_for_selector('.mfas img'); pg.wait_for_timeout(200)
        m=pg.evaluate("()=>{const f=document.querySelector('.mfas form').getBoundingClientRect();const b=document.querySelector('#mfok').getBoundingClientRect();return{l:f.left,r:f.right,over:document.documentElement.scrollWidth>innerWidth+1,bh:b.height,scroll:document.querySelector('.mfas').scrollHeight>=document.querySelector('.mfas form').scrollHeight}}")
        chk(f'{w}px: set-up dialog fits the screen and can be scrolled',m['l']>=0 and m['r']<=w and not m['over'] and m['scroll'],m); pg.screenshot(path=f'shots/mfa_setup_{w}.png',full_page=False)
        pg=page(br,USERS['sales'],w=w,h=780,ls={'fake.mfa':REQ,'fake.factors':F('sales@demo.test')}); ready(pg); pg.wait_for_selector('.mfas #mfc'); pg.screenshot(path=f'shots/mfa_code_{w}.png')
        pg=page(br,USERS['sup'],w=w,h=900,aal='aal2',ls={'fake.mfa':REQ,'fake.factors':F('sup@demo.test','sales@demo.test')}); ready(pg); toPanel(pg)
        m=pg.evaluate("()=>{const P=document.querySelector('#mfaPanel');return{over:document.documentElement.scrollWidth>innerWidth+1,pover:P.scrollWidth>P.clientWidth+1,cut:[...P.querySelectorAll('select')].filter(s=>s.getBoundingClientRect().right>innerWidth).length}}")
        chk(f'{w}px: Two-step panel has no sideways scroll or cut-off controls',not m['over'] and not m['pover'] and not m['cut'],m)
        pg.eval_on_selector('#mfaPanel','e=>e.scrollIntoView()'); pg.wait_for_timeout(100); pg.screenshot(path=f'shots/mfa_panel_{w}.png')
        pg.evaluate("()=>{S.setSec='sys';render()}"); pg.wait_for_selector('#backupPanel'); pg.click('#bkBtn'); pg.wait_for_function("()=>/^Done/.test(document.querySelector('#bkProg').innerText)",timeout=30000)
        m=pg.evaluate("()=>({over:document.documentElement.scrollWidth>innerWidth+1,b:[...document.querySelectorAll('#backupPanel .btn')].map(x=>x.getBoundingClientRect()).every(r=>r.right<=innerWidth&&r.height>=32)})")
        chk(f'{w}px: Backup panel fits, buttons usable',not m['over'] and m['b'],m); pg.eval_on_selector('#backupPanel','e=>e.scrollIntoView()'); pg.wait_for_timeout(100); pg.screenshot(path=f'shots/backup_{w}.png')
    br.close()
print(f'\n{ok} passed, {bad} failed'); sys.exit(1 if bad else 0)
