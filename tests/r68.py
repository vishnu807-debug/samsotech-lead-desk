# r68 · Part A feature 6: clickable stage boxes
import sys; sys.path.insert(0,'/home/claude/ld/t'); from h import *
ok=bad=0
def chk(n,c,extra=''):
    global ok,bad; ok+=bool(c); bad+=(not c); print(('PASS ' if c else 'FAIL ')+n+('' if c else '   '+str(extra)))
def openL(pg,id): pg.evaluate("id=>{closeDrawer&&S.drawer&&closeDrawer();openDrawer(id)}",id); pg.wait_for_selector('.lvh .stages'); pg.wait_for_timeout(120)
boxes=lambda pg: pg.eval_on_selector_all('.lvh .stages [data-stg]',"b=>b.map(x=>[x.dataset.stg,x.getAttribute('aria-disabled')!=='true',x.title,x.className])")
st=lambda pg,id: pg.evaluate("id=>S.leadMap[id].status",id)
act=lambda pg: pg.inner_html('#actArea')
norm=lambda h: re.sub(r'\s+',' ',re.sub(r'value="[^"]*"|min="[^"]*"|max="[^"]*"','',h))
def click(pg,s): pg.click(f'.lvh .stages [data-stg="{s}"]',force=True); pg.wait_for_timeout(150)
with sync_playwright() as p:
    br=p.chromium.launch()
    pg=page(br,USERS['sales']); ready(pg); D=pg.evaluate("window.__DEMO")
    # --- Assigned lead
    openL(pg,D['assigned']); B={b[0]:b for b in boxes(pg)}
    chk('assigned: six boxes, real buttons',len(B)==6 and list(B)==['New','Assigned','Meeting Done','Quotation Sent','Won','Lost'],list(B))
    chk('assigned: Meeting, Quote, Lost clickable; New, Assigned, Won not',[k for k in B if B[k][1]]==['Meeting Done','Quotation Sent','Lost'],[k for k in B if B[k][1]])
    chk('assigned: Won shows the reason',"meeting or the quotation first" in B['Won'][2],B['Won'][2])
    for stg,mode in [('Meeting Done','meet'),('Quotation Sent','quote'),('Lost','lost')]:
        click(pg,stg); a=norm(act(pg)); pg.evaluate("()=>{S.drawer.mode=null;drawDrawer()}"); pg.wait_for_timeout(80)
        pg.click(f'#actArea [data-m="{mode}"]'); pg.wait_for_timeout(120); b=norm(act(pg)); pg.evaluate("()=>{S.drawer.mode=null;drawDrawer()}"); pg.wait_for_timeout(80)
        chk(f'assigned: box "{stg}" opens exactly the same form as the button',a==b and len(a)>300,(len(a),len(b)))
    click(pg,'Quotation Sent'); h=act(pg)
    chk('quotation form still asks for the Salesforce quote, target date and next step',('type="file"' in h or 'Salesforce' in h) and 'arget' in h and 'ext step' in h)
    pg.click('#a-save') if pg.query_selector('#a-save') else None; pg.wait_for_timeout(200)
    chk('quotation cannot be saved without the upload: status unchanged',st(pg,D['assigned'])=='Assigned')
    pg.evaluate("()=>{S.drawer.mode=null;drawDrawer()}")
    click(pg,'Won'); chk('blocked box: tap shows the reason, nothing changes',"quotation first" in pg.inner_text('#toastHost') and st(pg,D['assigned'])=='Assigned' and 'Update stage' in pg.inner_text('#actArea'))
    pg.focus('.lvh .stages [data-stg="Meeting Done"]'); pg.keyboard.press('Enter'); pg.wait_for_timeout(150)
    chk('keyboard: Enter on a box opens the form','Meeting done' in pg.inner_text('#actArea'))
    pg.evaluate("()=>{S.drawer.mode=null;drawDrawer()}")
    # --- Meeting Done lead
    openL(pg,D['meeting']); B={b[0]:b for b in boxes(pg)}
    chk('meeting: Quote, Won, Lost clickable',[k for k in B if B[k][1]]==['Quotation Sent','Won','Lost'],[k for k in B if B[k][1]])
    click(pg,'Won'); chk('meeting → Won without a quotation: sent to the quotation form, not won',('no quotation yet' in pg.inner_text('#actArea')) and st(pg,D['meeting'])=='Meeting Done')
    chk('current stage is marked',pg.get_attribute('.lvh .stages [data-stg="Meeting Done"]','aria-current')=='step')
    # --- Quotation Sent lead
    openL(pg,D['quote']); B={b[0]:b for b in boxes(pg)}
    chk('quote: Won and Lost clickable only',[k for k in B if B[k][1]]==['Won','Lost'],[k for k in B if B[k][1]])
    click(pg,'Won'); h=pg.inner_text('#actArea'); chk('quote → Won: value comes from the quotation, no amount box','AED 48,500' in h.replace('48.5K','48,500') or 'taken from quotation' in h, h[:200])
    chk('quote → Won: no typed amount field',pg.eval_on_selector('#a-val','e=>e.type')=='hidden')
    pg.evaluate("()=>{S.drawer.mode=null;drawDrawer()}"); pg.evaluate("id=>{S.leadMap[id].pms=''}",D['quote']); click(pg,'Won'); a1=norm(act(pg)); pg.click('#a-save'); pg.wait_for_timeout(250)
    chk('quote → Won: the PMS is still asked for and required',('PMS' in pg.inner_text('#actArea')) and st(pg,D['quote'])=='Quotation Sent',pg.inner_text('#actArea')[:200])
    pg.evaluate("()=>{S.drawer.mode=null;drawDrawer()}"); pg.click('#actArea [data-m="won"]'); pg.wait_for_timeout(120); chk('quote → Won: box and button give the same form',a1==norm(act(pg)))
    pg.evaluate("()=>{S.drawer.mode=null;drawDrawer()}")
    click(pg,'Lost'); pg.click('#l-save'); pg.wait_for_timeout(200); chk('Lost without a reason is refused',st(pg,D['quote'])=='Quotation Sent')
    n0=pg.evaluate("window.__FAKE.DB.audit_log.length")
    pg.select_option('#l-r','Price'); pg.click('#l-save'); pg.wait_for_function("id=>S.leadMap[id].status==='Lost'",arg=D['quote'],timeout=5000)
    chk('Lost with a reason saves through the normal path',st(pg,D['quote'])=='Lost' and pg.evaluate("id=>S.leadMap[id].lost&&S.leadMap[id].lost.reason",D['quote'])=='Price')
    chk('…and is recorded (lead log + audit trail) as today',pg.evaluate("id=>S.leadMap[id].log.slice(-1)[0].a",D['quote']).startswith('Lost') and pg.evaluate("window.__FAKE.DB.audit_log.length")>n0)
    pg.wait_for_timeout(200); B={b[0]:b for b in boxes(pg)}
    chk('lost lead: only the reopen box is clickable, Lost box filled',[k for k in B if B[k][1]]==['Quotation Sent'] and 'lost' in B['Lost'][3],B)
    # --- On hold: reopen needs a confirm
    openL(pg,D['hold']); B={b[0]:b for b in boxes(pg)}
    chk('on hold: reopen box + same moves as the buttons',B['Meeting Done'][1] and 'Reopen' in B['Meeting Done'][2] and B['Quotation Sent'][1] and B['Won'][1] and B['Lost'][1])
    click(pg,'Meeting Done'); chk('no-form move asks for a confirm first',pg.query_selector('#cfm #sgOk') is not None and st(pg,D['hold'])=='On Hold')
    pg.click('#cfm [data-cfmx]'); pg.wait_for_timeout(100); chk('cancel leaves the lead unchanged',st(pg,D['hold'])=='On Hold' and not pg.query_selector('#cfm'))
    click(pg,'Meeting Done'); pg.click('#sgOk'); pg.wait_for_function("id=>S.leadMap[id].status==='Meeting Done'",arg=D['hold'],timeout=5000); chk('confirm reopens to the right stage',True)
    # --- own Won inside 30 days
    openL(pg,D['wonNew']); B={b[0]:b for b in boxes(pg)}
    chk('own won lead (4 days): can go back to Assigned / Meeting / Quote, not Lost or New',[k for k in B if B[k][1]]==['Assigned','Meeting Done','Quotation Sent'],[k for k in B if B[k][1]])
    click(pg,'Meeting Done'); chk('opens the move-back form with that stage chosen',pg.input_value('#uw-s')=='Meeting Done' and 'Meetings stay' in pg.inner_text('#uw-h').replace('meetings stay','Meetings stay'),pg.inner_text('#uw-h'))
    pg.click('#uw-ok'); pg.wait_for_timeout(150); chk('…and still asks to confirm before changing',pg.query_selector('#cfm #uwOk') is not None and st(pg,D['wonNew'])=='Won'); pg.click('#cfm [data-cfmx]')
    # --- own Won after 30 days
    openL(pg,D['wonOld']); B={b[0]:b for b in boxes(pg)}
    chk('own won lead (80 days): nothing clickable, reason given',not any(b[1] for b in B.values()) and '30 days' in B['Assigned'][2],B['Assigned'][2])
    # --- read-only: generated by me
    openL(pg,D['gen']); chk('generated-by-me lead (read-only): plain boxes, no buttons',len(boxes(pg))==0 and pg.eval_on_selector_all('.lvh .stages span','s=>s.length')==5)
    chk('no script errors (sales)',not pg.errors,pg.errors[:2])
    # --- Lead Manager
    pg=page(br,USERS['lm']); ready(pg)
    openL(pg,D['wonOld']); B={b[0]:b for b in boxes(pg)}
    chk('Lead Manager on an old won lead: Assigned, Meeting, Quote, Lost clickable',[k for k in B if B[k][1]]==['Assigned','Meeting Done','Quotation Sent','Lost'],[k for k in B if B[k][1]])
    click(pg,'Assigned'); pg.click('#uw-ok'); pg.wait_for_timeout(150); chk('override user must still give a reason',not pg.query_selector('#cfm') and 'Explain why' in pg.inner_text('#uw-msg'))
    openL(pg,D['other']); chk("Lead Manager: another engineer's lead is clickable",any(b[1] for b in boxes(pg)))
    chk('no script errors (lead manager)',not pg.errors,pg.errors[:2])
    # --- Supervisor
    pg=page(br,USERS['sup']); ready(pg); openL(pg,D['assigned']); chk('Supervisor: boxes clickable',[b[0] for b in boxes(pg) if b[1]]==['Meeting Done','Quotation Sent','Lost'])
    # --- Management and AMC: read-only
    for k in ('mg','amc'):
        pg=page(br,USERS[k]); ready(pg); openL(pg,D['wonNew']); chk(f'{k}: read-only, no clickable stages',len(boxes(pg))==0 and not pg.errors,pg.errors[:2])
    # --- sizes
    for w in (320,390,768,1024,1440):
        pg=page(br,USERS['sales'],w=w,h=800); ready(pg); openL(pg,D['assigned'])
        m=pg.evaluate("()=>{const b=[...document.querySelectorAll('.lvh .stages [data-stg]')];const h=document.querySelector('.lvh');return{minH:Math.min(...b.map(x=>x.getBoundingClientRect().height)),minW:Math.min(...b.map(x=>x.getBoundingClientRect().width)),cut:b.filter(x=>x.scrollWidth>x.clientWidth+1).map(x=>x.textContent),over:h.scrollWidth>h.clientWidth+1||document.documentElement.scrollWidth>innerWidth+1}}")
        chk(f'{w}px: boxes fit, labels not cut, no sideways scroll'+(', at least 44px tall' if w<768 else ''),not m['cut'] and not m['over'] and (m['minH']>=44 if w<768 else m['minH']>=30),m)
        pg.screenshot(path=f'shots/stage_{w}.png')
    br.close()
print(f'\n{ok} passed, {bad} failed'); sys.exit(1 if bad else 0)
