// libFuzzer harness: parse arbitrary bytes as DIMACS CNF (incl. xor clauses) and solve.
// Port of upstream's in-tree src/fuzz.cpp (which no longer compiles against the current parser API); invalid input -> -1.
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include "cryptominisat.h"
#include "dimacsparser.h"

namespace {
struct MyText {
    const unsigned char* txt = nullptr;
    size_t size = 0;
    size_t at = 0;
};

struct TextReader {
    static inline int read(void* buf, size_t num, size_t count, MyText* f)
    {
        size_t toread = num * count;
        if (toread > f->size - f->at) {
            toread = f->size - f->at;
        }
        memcpy(buf, f->txt + f->at, toread);
        f->at += toread;
        return (int)toread;
    }
};

// The DIMACS parser calls exit(-1) on 'b' lines (BNN is not compiled in), on an unknown 'c p <text>', on
// 'c p weight|show|optshow' after a 'c ind', and on a malformed or zero 'c p weight'; and its parseInt()
// overflows a signed int before it detects an overlong number. Nothing in the harness may exit, so Scan
// walks the input exactly as DimacsParser::parse_DIMACS_main would (same dispatch, same tokenisation, a
// 0xFF byte reads as EOF) and turns away every input that would exit, fail to parse, or hold a number
// of more than 3 digits. Valid 'c p' lines and everything else reach the real parser.
struct Scan {
    const unsigned char* d;
    size_t n;
    size_t pos = 0;

    int value() const { return pos >= n ? EOF : (int)(signed char)d[pos]; }
    void advance() { pos++; }
    void skipWhitespace() { for (int c = value(); c == '\t' || c == '\r' || c == ' '; c = value()) advance(); }
    void skipLine()
    {
        for (;;) {
            const int c = value();
            if (c == EOF || c == '\0') return;
            advance();
            if (c == '\n') return;
        }
    }
    bool skipEOL()
    {
        for (;;) {
            const int c = value();
            if (c == EOF || c == '\0') return true;
            if (c == '\n') { advance(); return true; }
            if (c != '\r') return false;
            advance();
        }
    }
    std::string parseString()
    {
        skipWhitespace();
        std::string s;
        while (value() != ' ' && value() != '\n' && value() != EOF) { s.push_back((char)value()); advance(); }
        return s;
    }
    void skipRemain() { while (value() != EOF && value() != '\0' && value() != '\n') advance(); }

    // Numbers are capped at 3 digits (StreamBuffer::parseInt overflows int beyond that).
    bool parseInt(int& ret)
    {
        skipWhitespace();
        int mult = 1;
        if (value() == '-') { mult = -1; advance(); }
        else if (value() == '+') advance();
        if (value() < '0' || value() > '9') return false;
        int val = 0, digits = 0;
        while (value() >= '0' && value() <= '9') {
            if (++digits > 3) return false;
            val = val * 10 + (value() - '0');
            advance();
        }
        ret = mult * val;
        return true;
    }
    bool readClause()
    {
        for (;;) {
            int lit;
            if (!parseInt(lit)) return false;
            if (lit == 0) return true;
            if (value() != ' ') return false;
        }
    }
    bool readSet()
    {
        for (;;) {
            int lit;
            if (!parseInt(lit)) return false;
            if (lit == 0) return true;
        }
    }

    bool comment(bool& ind_set)
    {
        const std::string str = parseString();
        if (str == "red") {
            skipWhitespace();
            if (!readClause()) return false;
        } else if (str == "MUST") {
            skipWhitespace();
            if (parseString() != "MULTIPLY") return false;
            skipWhitespace();
            if (parseString() != "BY") return false;
            skipWhitespace();
            skipRemain();
        } else if (str == "ind") {
            if (!readSet()) return false;
            ind_set = true;
        } else if (str == "t") {
            skipWhitespace();
            parseString();
        } else if (str == "p") {
            skipWhitespace();
            const std::string str2 = parseString();
            if (str2 == "weight") {
                if (ind_set) return false;
                int lit;
                if (!parseInt(lit) || lit == 0) return false;
                skipRemain();
            } else if (str2 == "show" || str2 == "optshow") {
                if (ind_set) return false;
                skipWhitespace();
                if (!readSet()) return false;
            } else if (str2 == "exist" || str2 == "no-touch") {
                skipWhitespace();
                if (!readSet()) return false;
            } else {
                return false;
            }
        }
        skipLine();
        return true;
    }

    bool run()
    {
        bool ind_set = false;
        for (;;) {
            skipWhitespace();
            switch (value()) {
            case EOF:
                return true;
            case 'p': {
                advance();
                skipWhitespace();
                int vars, cls;
                if (parseString() != "cnf" || !parseInt(vars) || !parseInt(cls) || vars < 0 || cls < 0) return false;
                skipLine();
                break;
            }
            case 'e':
                advance();
                skipLine();
                break;
            case 'a':
                advance();
                if (!readSet()) return false;
                break;
            case 'c':
                advance();
                if (!comment(ind_set)) return false;
                break;
            case 'x':
                advance();
                if (!readClause() || !skipEOL()) return false;
                break;
            case 'b':
                return false;
            case '\n':
                skipLine();
                break;
            default:
                if (!readClause()) return false;
                skipWhitespace();
                if (!skipEOL()) return false;
                break;
            }
        }
    }
};

bool parser_would_reject(const unsigned char* d, size_t n)
{
    Scan s{d, n};
    return !s.run();
}
}

extern "C" int LLVMFuzzerTestOneInput(const unsigned char* data, size_t size)
{
    if (parser_would_reject(data, size)) return -1;
    CMSat::SATSolver S;
    S.set_verbosity(0);
    S.set_max_confl(20000);

    std::unique_ptr<CMSat::FieldGen> fg = std::make_unique<CMSat::FGenDouble>();
    CMSat::DimacsParser<CMSat::StreamBuffer<MyText*, TextReader>, CMSat::SATSolver> parser(&S, nullptr, 0, fg);
    parser.max_var = 1000;
    MyText t;
    t.txt = data;
    t.size = size;
    t.at = 0;
    if (!parser.parse_DIMACS(&t, false)) {
        return -1;
    }
    S.solve();
    return 0;
}
