#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdint.h>
#include <time.h>
static long now_ms(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1000L+t.tv_nsec/1000000L;}
#define REPORT(name,s,chk) printf("%s %ldms chk=%lld\n",name,now_ms()-(s),(long long)(chk))
static int cmp(const void*a,const void*b){int64_t x=*(int64_t*)a,y=*(int64_t*)b;return (x>y)-(x<y);}
typedef struct{int64_t k,v;}KV;
static int cmpkv(const void*a,const void*b){int64_t x=((KV*)a)->k,y=((KV*)b)->k;return (x>y)-(x<y);}
int main(void){
  const int64_t n=2000000;
  int64_t*xs=malloc(n*8);double*fs=malloc(n*8);
  for(int64_t i=0;i<n;i++)xs[i]=(i*7919)%100003;
  for(int64_t i=0;i<n;i++)fs[i]=(double)xs[i]*0.5;
  char (*strs)[16]=malloc(200000*16);
  for(int i=0;i<200000;i++)snprintf(strs[i],16,"%lld",(long long)xs[i]);
  long s;int64_t c;
  s=now_ms();c=0;for(int r=0;r<20;r++){int64_t t=0;for(int64_t i=0;i<n;i++)t+=xs[i];c+=t;}REPORT("sum_int_x20",s,c);
  s=now_ms();c=0;for(int r=0;r<20;r++){int64_t mx=xs[0],mn=xs[0];for(int64_t i=0;i<n;i++){if(xs[i]>mx)mx=xs[i];if(xs[i]<mn)mn=xs[i];}c+=n+mx+mn;}REPORT("len_max_min_x20",s,c);
  s=now_ms();int64_t*ys=malloc(n*8);memcpy(ys,xs,n*8);qsort(ys,n,8,cmp);REPORT("sorted_int_2M",s,ys[1000]);
  s=now_ms();KV*kv=malloc(n*sizeof(KV));for(int64_t i=0;i<n;i++){kv[i].k=-xs[i];kv[i].v=xs[i];}qsort(kv,n,sizeof(KV),cmpkv);REPORT("sorted_key_2M",s,kv[1000].v);
  s=now_ms();c=0;for(int64_t i=0;i<n;i++)c+=i+xs[i];REPORT("enumerate_2M",s,c);
  s=now_ms();c=0;for(int64_t i=0;i<n;i++)c+=xs[i]-xs[i]+1;REPORT("zip_2M",s,c);
  s=now_ms();int64_t*m=malloc(n*8);for(int64_t i=0;i<n;i++)m[i]=xs[i]+1;REPORT("map_2M",s,m[5]);
  s=now_ms();int64_t*f=malloc(n*8);int64_t fn=0;for(int64_t i=0;i<n;i++)if(xs[i]%2==0)f[fn++]=xs[i];REPORT("filter_2M",s,fn);
  s=now_ms();int64_t*rv=malloc(n*8);for(int64_t i=0;i<n;i++)rv[i]=xs[n-1-i];REPORT("reversed_2M",s,rv[0]);
  s=now_ms();c=0;for(int64_t i=0;i<n;i++){int64_t v=xs[i];c+=llabs(v-50000)+(int64_t)nearbyint((double)v*0.5);}REPORT("abs_round_2M",s,c);
  s=now_ms();c=0;for(int64_t i=0;i<n;i++){int64_t v=xs[i];int64_t q=v/7,r=v%7;c+=q+r;}REPORT("divmod_2M",s,c);
  s=now_ms();c=0;for(int i=0;i<200000;i++)c+=strtoll(strs[i],0,10);REPORT("int_from_str_200k",s,c);
  s=now_ms();c=0;{char b[32];for(int64_t i=0;i<500000;i++)c+=snprintf(b,32,"%lld",(long long)xs[i]);}REPORT("str_from_int_500k",s,c);
  s=now_ms();c=0;for(int r=0;r<20;r++){int a=0;for(int64_t i=0;i<n;i++)if(xs[i]>100000){a=1;break;}c+=a;int al=1;for(int64_t i=0;i<n;i++)if(!(xs[i]>=0)){al=0;break;}c+=al;}REPORT("any_all_gen_x20",s,c);
  s=now_ms();c=0;for(int64_t i=0;i<n;i++)c+=(int64_t)fs[i];REPORT("int_from_float_2M",s,c);
  s=now_ms();int64_t*ls=malloc(n*8);for(int64_t i=0;i<n;i++)ls[i]=i;REPORT("list_range_2M",s,ls[10]);
  s=now_ms();c=0;for(int64_t i=0;i<n;i++){int64_t v=xs[i];c+=(v<50000?v:50000)+(v>20000?v:20000);}REPORT("min2_max2_2M",s,c);
  return 0;}
