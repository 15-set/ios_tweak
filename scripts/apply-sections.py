import sys,json
# 分类配置 sections.json：
#   {"sections":[{"name":"显示名","orig":"原分类","pkgs":["包名", "-排除包名"]}], "other":"其它"}
# 规则：
#   1) pkgs 里点名的包进本分类（可以同时属于多个分类）
#   2) orig 不为空时，原本属于该分类的包自动进本分类，"-包名" 表示踢出去
#   3) 没有任何分类收走的包，统一进 other
OTHER='插件'
# 兜底分类：没被任何分类收走的包统一放这里，默认不可删除、不在分类列表显示
OTHER_OUT=OTHER
try: cfg=json.load(open('sections.json',encoding='utf-8'))
except Exception: cfg={}
# 兼容老格式 {"keep":[...]}：当成「只保留这几个原分类」
raw=cfg.get('sections')
if raw is None:
    raw=[{'name':k,'orig':k,'pkgs':[]} for k in (cfg.get('keep') or [])]
# 兜底分类名固定为「插件」：不再读老配置里的 "other" 字段，
# 之前正是这个字段让「～其它」一路传下来。
_oc=(cfg.get('other') or '').strip()
if _oc and _oc!=OTHER: print('提示：忽略旧配置里的 other=%r，兜底分类固定为「%s」' % (_oc, OTHER))
OTHER_OUT=OTHER
if not raw:
    print('sections.json 没有分类配置，跳过'); sys.exit(0)
sections=[]
for s in raw:
    if not s or not str(s.get('name','')).strip(): continue
    sections.append({
        'name': str(s['name']).strip(),
        'orig': str(s.get('orig') or '').strip(),
        'pkgs': [str(x) for x in (s.get('pkgs') or [])]
    })
if not sections:
    print('分类配置为空，跳过'); sys.exit(0)
# 已废弃的「其它」兜底分类：配置里若还残留就丢掉，不再参与分组
o_sections=[s for s in sections if s['name']!=OTHER]   # 真实分类（不含兜底）
sections=[s for s in sections if s['name']!=OTHER]

txt=open('Packages',encoding='utf-8').read()
SEP=chr(10)+chr(10); NL=chr(10)
blocks=[b for b in txt.split(SEP) if b.strip()]
# 解析每个包：包名 / 原分类 / 原始块
pkgs=[]
for b in blocks:
    m=pkg=None
    cur=''
    for l in b.split(NL):
        if l.startswith('Package:'): pkg=l.split(':',1)[1].strip()
        elif l.startswith('Section:'):
            cur=l.split(':',1)[1].strip()
            if cur==OTHER_OUT: cur=OTHER   # 带前缀的兜底分类还原成「其它」
    pkgs.append({'pkg':pkg,'sec':cur,'block':b})

# 计算每个分类收哪些包
members={}   # 分类名 -> [包名]
claimed=set()
SEC_NAMES=set(s['name'] for s in sections)
# 分类唯一：一个包只能属于一个分类。按分类顺序，先认领的分类独占，
# 后面的分类即使勾选了同一包也拿不到（前端编辑界面也会把已归属的包置灰）
_taken=set()
for s in sections:
    st=set()
    for x in s['pkgs']:
        if x.startswith('-'): continue
        st.add(x)
    if s['orig']:
        for p in pkgs:
            if p['sec']==s['orig']: st.add(p['pkg'])
    for x in s['pkgs']:
        if x.startswith('-'): st.discard(x[1:])
    st -= _taken                      # 已被前面分类独占的包，本分类不能再拿
    members[s['name']]=members.get(s['name'],set())|st
    _taken |= st
    claimed|=st
rest=set(p['pkg'] for p in pkgs)-claimed
# 兜底分类自愈（这一段之前只写在 sections 循环里，但「插件」在循环前就被滤掉了，永远跑不到）：
# 把落在"无效分区"里的包认领给兜底分类。无效分区 = 既不是任何分类的显示名，
# 也不是任何分类的 orig，典型就是历史遗留的「～其它」/「其它」。
# 没有这一段，一旦线上被写成「～其它」，兜底分类永远认领不到，全源会卡死。
_sec_names=set(s['name'] for s in sections)|set([OTHER])
_orig_names=set(s['orig'] for s in sections if s['orig'])
for p in pkgs:
    sec=p['sec']
    if not sec or sec in _sec_names or sec in _orig_names: continue
    rest.add(p['pkg'])

# 输出：包按分类顺序展开，同一包属于多个分类就出现多条
out=[]; multi=0
bypkg={}
for p in pkgs: bypkg.setdefault(p['pkg'],p)
done_names=set()
emitted=set()   # 已写出的包名，保证每个包只出现一次
for s in sections:
    if s['name'] in done_names: continue   # 同名分类已经合并输出过
    done_names.add(s['name'])
    # 同一包名在 Packages 里可能出现多次（历史重复数据），这里按包名去重，避免写出重复段落
    for name in dict.fromkeys(p['pkg'] for p in pkgs if p['pkg'] in members[s['name']]):
        if name in emitted: continue
        emitted.add(name)
        src=bypkg.get(name)
        if not src: continue
        lines=[l for l in src['block'].split(NL) if not l.startswith('Section:')]
        # Section 放在 Description 之前，和 apt-ftparchive 的输出顺序一致
        at=len(lines)
        for i,l in enumerate(lines):
            if l.startswith('Description:'): at=i; break
        lines.insert(at,'Section: '+s['name'])
        out.append(NL.join(lines)); multi+=1
for name in dict.fromkeys(p['pkg'] for p in pkgs if p['pkg'] in rest):
    if name in emitted: continue
    emitted.add(name)
    src=bypkg.get(name)
    if not src: continue
    lines=[l for l in src['block'].split(NL) if not l.startswith('Section:')]
    at=len(lines)
    for i,l in enumerate(lines):
        if l.startswith('Description:'): at=i; break
    # 没被任何分类收走的包统一进「插件」（默认兜底分类）
    lines.insert(at,'Section: '+OTHER_OUT)
    out.append(NL.join(lines)); multi+=1

total=len(set(p['pkg'] for p in pkgs))
# 硬规则：结果里只允许出现配置内的分类名，「～其它」这类历史遗留分区一律不许写出去。
# 兜底分类已经接管了所有认领不到的包，所以正常情况 rest 会兜住全部。
# 唯一的中止条件：配置里的分类全都认领不到，而且兜底也一个包都收不到——那说明配置本身烂了。
dead=[s['name'] for s in o_sections if not (members.get(s['name']) or set())]
if total>0 and not rest and not claimed:
    print('已中止：所有插件都无法归入任何分类，配置可能有误。Packages 未改动。')
    sys.exit(0)
if dead:
    print('提示：分类 %s 暂时没有认领到插件（原分区已不存在），其插件已归入「%s」。'
          % ('、'.join(dead), OTHER_OUT))
open('Packages','w',encoding='utf-8').write(SEP.join(out)+NL)
names=', '.join(s['name'] for s in sections)
# 统计一律按「插件」算，不按分类记录算：一个插件跨 3 个分类也只算 1 个
uniq=len(set(p['pkg'] for p in pkgs))
print('分类完成：%d 个插件（%d 个进「插件」）；分类 %d 个: %s'
      % (uniq, len(rest), len(sections), names))