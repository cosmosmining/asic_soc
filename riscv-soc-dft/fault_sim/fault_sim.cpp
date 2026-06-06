// fault_sim - parallel-pattern stuck-at fault simulator for ISCAS'85 .bench
// circuits. Packs 64 random test patterns per machine word (PPSFP-style bit
// parallelism), runs a fault-free reference, then for every line stuck-at-0/1
// injects the fault and re-simulates, marking it detected if any primary output
// differs. Reports stuck-at fault coverage vs pattern count.
//
//   build: g++ -O2 -std=c++17 -o fault_sim fault_sim.cpp
//   run:   ./fault_sim c17.bench [num_patterns] [seed]
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <unordered_map>
#include <random>
using namespace std;

enum GType { AND, NAND, OR, NOR, NOT_, BUF, XOR_, XNOR };
struct Gate { int out; GType type; vector<int> ins; };

static unordered_map<string,int> sigid;
static vector<string> signame;
static vector<int> PIs, POs;
static vector<Gate> gates;            // already in file (topological) order

static int getid(const string& s) {
    auto it = sigid.find(s);
    if (it != sigid.end()) return it->second;
    int id = signame.size(); sigid[s] = id; signame.push_back(s); return id;
}
static GType gtype(const string& s) {
    if (s=="AND")  return AND;
    if (s=="NAND") return NAND;
    if (s=="OR")   return OR;
    if (s=="NOR")  return NOR;
    if (s=="NOT"||s=="INV")  return NOT_;
    if (s=="BUFF"||s=="BUF") return BUF;
    if (s=="XOR")  return XOR_;
    if (s=="XNOR") return XNOR;
    fprintf(stderr,"unknown gate %s\n",s.c_str()); exit(1);
}

// strip a token of spaces/parens/commas
static string clean(string s){ string o; for(char c:s) if(!isspace(c)&&c!='('&&c!=')'&&c!=',') o+=c; return o; }

static void parse(const char* path){
    FILE* f=fopen(path,"r"); if(!f){perror(path);exit(1);}
    char line[1024];
    while(fgets(line,sizeof line,f)){
        char* h=strchr(line,'#'); if(h)*h=0;
        string L(line); if(L.find_first_not_of(" \t\r\n")==string::npos) continue;
        if(L.find("INPUT")!=string::npos){ string n=clean(L.substr(L.find("INPUT")+5)); PIs.push_back(getid(n)); }
        else if(L.find("OUTPUT")!=string::npos){ string n=clean(L.substr(L.find("OUTPUT")+6)); POs.push_back(getid(n)); }
        else if(L.find('=')!=string::npos){
            size_t eq=L.find('='); string lhs=clean(L.substr(0,eq));
            string rhs=L.substr(eq+1); size_t lp=rhs.find('(');
            string gt; for(char c:rhs.substr(0,lp)) if(!isspace(c)) gt+=c;
            Gate g; g.out=getid(lhs); g.type=gtype(gt);
            string args=rhs.substr(lp+1); string cur;
            for(char c:args){ if(c==','||c==')'){ if(!cur.empty()){string t;for(char d:cur)if(!isspace(d))t+=d; if(!t.empty())g.ins.push_back(getid(t)); cur.clear();} } else cur+=c; }
            gates.push_back(g);
        }
    }
    fclose(f);
}

// evaluate all signals for one fault (fsig<0 => fault-free; fval is 0/1 stuck).
static void simulate(vector<uint64_t>& v, int W, int fsig, uint64_t fmask /*per-word? use all-ones*/, int fval){
    // PI fault override
    if(fsig>=0){ for(int pi:PIs) if(pi==fsig) for(int w=0;w<W;w++) v[pi*W+w]= fval? ~0ull:0ull; }
    for(const Gate& g: gates){
        for(int w=0; w<W; w++){
            uint64_t r;
            const auto& in=g.ins;
            switch(g.type){
                case AND:  r=~0ull; for(int a:in) r&=v[a*W+w]; break;
                case NAND: r=~0ull; for(int a:in) r&=v[a*W+w]; r=~r; break;
                case OR:   r=0;     for(int a:in) r|=v[a*W+w]; break;
                case NOR:  r=0;     for(int a:in) r|=v[a*W+w]; r=~r; break;
                case NOT_: r=~v[in[0]*W+w]; break;
                case BUF:  r= v[in[0]*W+w]; break;
                case XOR_: r=0; for(int a:in) r^=v[a*W+w]; break;
                case XNOR: r=0; for(int a:in) r^=v[a*W+w]; r=~r; break;
                default:   r=0;
            }
            if(g.out==fsig) r = fval? ~0ull:0ull;     // gate-output stuck-at
            v[g.out*W+w]=r;
        }
    }
    (void)fmask;
}

int main(int argc,char**argv){
    if(argc<2){ printf("usage: %s <bench> [patterns] [seed]\n",argv[0]); return 1; }
    int K = argc>2? atoi(argv[2]) : 1024;       // number of random patterns
    unsigned seed = argc>3? (unsigned)atoi(argv[3]) : 1;
    parse(argv[1]);
    int N = signame.size();
    int W = (K+63)/64;

    // fault-free reference with random PI patterns
    vector<uint64_t> good(N*W,0);
    mt19937_64 rng(seed);
    for(int pi:PIs) for(int w=0;w<W;w++) good[pi*W+w]=rng();
    simulate(good,W,-1,0,0);

    // collect faults: SA0 and SA1 on every signal (PI + gate output)
    int total=0, detected=0;
    vector<uint64_t> v(N*W);
    auto run_fault=[&](int sig,int sval)->bool{
        v = good;                                  // restore PI patterns + recompute
        // reset gate outputs so simulate recomputes them (PIs stay)
        simulate(v,W,sig,0,sval);
        for(int po:POs) for(int w=0;w<W;w++) if(v[po*W+w]!=good[po*W+w]) return true;
        return false;
    };
    for(int s=0;s<N;s++){
        // skip signals that are neither PI nor a gate output (shouldn't happen)
        total+=2;
        if(run_fault(s,0)) detected++;
        if(run_fault(s,1)) detected++;
    }
    double cov = total? 100.0*detected/total : 0.0;
    printf("circuit:   %s\n", argv[1]);
    printf("signals:   %d   gates: %zu   PIs: %zu   POs: %zu\n", N, gates.size(), PIs.size(), POs.size());
    printf("patterns:  %d (random, seed %u)\n", K, seed);
    printf("faults:    %d (stuck-at-0/1 per line)\n", total);
    printf("detected:  %d\n", detected);
    printf("COVERAGE:  %.2f%% stuck-at\n", cov);
    return 0;
}
