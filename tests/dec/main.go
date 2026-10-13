package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/shopspring/decimal"
)

func main() {
	sc := bufio.NewScanner(os.Stdin)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	for sc.Scan() {
		f := strings.Split(sc.Text(), " ")
		p := func(s string) (decimal.Decimal, bool) { d, e := decimal.NewFromString(s); return d, e == nil }
		switch f[0] {
		case "parse":
			d, ok := p(f[1])
			fmt.Fprintln(w, ok, d.String())
		case "float":
			x, _ := strconv.ParseFloat(f[1], 64)
			fmt.Fprintln(w, decimal.NewFromFloat(x).String())
		default:
			a, _ := p(f[1])
			b, _ := p(f[2])
			var r string
			switch f[0] {
			case "add":
				r = a.Add(b).String()
			case "sub":
				r = a.Sub(b).String()
			case "mul":
				r = a.Mul(b).String()
			case "div":
				if b.IsZero() {
					r = "divzero"
				} else {
					r = a.Div(b).String()
				}
			case "cmp":
				r = fmt.Sprint(a.Cmp(b))
			case "floor":
				n, _ := strconv.Atoi(f[2])
				r = a.RoundFloor(int32(n)).String()
			case "ceil":
				n, _ := strconv.Atoi(f[2])
				r = a.RoundCeil(int32(n)).String()
			case "f64":
				r = strconv.FormatFloat(a.InexactFloat64(), 'g', -1, 64)
			}
			fmt.Fprintln(w, r)
		}
	}
}
