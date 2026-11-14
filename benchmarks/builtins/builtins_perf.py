import time
def now_ms(): return int(time.perf_counter()*1000)
def report(name,start,chk): print(name, str(now_ms()-start)+"ms chk="+str(chk))
def main():
    n=2000000
    xs=[(i*7919)%100003 for i in range(n)]
    fs=[float(v)*0.5 for v in xs]
    strs=[str(v) for v in xs[:200000]]
    s=now_ms(); c=0
    for r in range(20): c+=sum(xs)
    report("sum_int_x20",s,c)
    s=now_ms(); c=0
    for r in range(20): c+=len(xs)+max(xs)+min(xs)
    report("len_max_min_x20",s,c)
    s=now_ms(); ys=sorted(xs); report("sorted_int_2M",s,ys[1000])
    s=now_ms(); ys2=sorted(xs,key=lambda v:-v); report("sorted_key_2M",s,ys2[1000])
    s=now_ms(); c=0
    for idx,v in enumerate(xs): c+=idx+v
    report("enumerate_2M",s,c)
    s=now_ms(); c=0
    for a,b in zip(xs,xs): c+=a-b+1
    report("zip_2M",s,c)
    s=now_ms(); m=list(map(lambda v:v+1,xs)); report("map_2M",s,m[5])
    s=now_ms(); f=list(filter(lambda v:v%2==0,xs)); report("filter_2M",s,len(f))
    s=now_ms(); rv=list(reversed(xs)); report("reversed_2M",s,rv[0])
    s=now_ms(); c=0
    for v in xs: c+=abs(v-50000)+round(float(v)*0.5)
    report("abs_round_2M",s,c)
    s=now_ms(); c=0
    for v in xs:
        q,rem=divmod(v,7); c+=q+rem
    report("divmod_2M",s,c)
    s=now_ms(); c=0
    for t in strs: c+=int(t)
    report("int_from_str_200k",s,c)
    s=now_ms(); c=0
    for v in xs[:500000]: c+=len(str(v))
    report("str_from_int_500k",s,c)
    s=now_ms(); c=0
    for r in range(20):
        if any(v>100000 for v in xs): c+=1
        if all(v>=0 for v in xs): c+=1
    report("any_all_gen_x20",s,c)
    s=now_ms(); c=0
    for v in fs: c+=int(v)
    report("int_from_float_2M",s,c)
    s=now_ms(); ls=list(range(n)); report("list_range_2M",s,ls[10])
    s=now_ms(); c=0
    for v in xs: c+=min(v,50000)+max(v,20000)
    report("min2_max2_2M",s,c)
main()
