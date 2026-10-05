// User-owned LawSpec adapter: adding through a server process, talking over
// the generated Serve and Hire channel ends.
package sessions

// serve receives two numbers and sends their sum.
func serve(end ServeFirstReceiveInt32Step1) {
	a, end2 := end.Receive()
	b, end3 := end2.Receive()
	end3.Send(int64(a) + int64(b))
}

// ask sends a and b to a server and receives the sum.
func ask(end ServeSecondSendInt32Step1, a, b int32) int64 {
	sum, _ := end.Send(a).Send(b).Receive()
	return sum
}

// Add implements add :: (Int32 -> (Int32 -> Integer)).
func Add(value0 int32, value1 int32) any {
	server, client := OpenServe()
	var sum int64
	LawSpecPar(
		func() { serve(server) },
		func() { sum = ask(client, value0, value1) },
	)
	return new(LawSpecBigInt).SetInt64(sum)
}

// AddHired implements addHired :: (Int32 -> (Int32 -> Integer)).
func AddHired(value0 int32, value1 int32) any {
	boss, manager := OpenHire()
	server, client := OpenServe()
	worker := LawSpecSpawn(func() {
		hired, _ := manager.Receive()
		serve(hired)
	})
	boss.Send(server)
	sum := ask(client, value0, value1)
	worker.Join()
	return new(LawSpecBigInt).SetInt64(sum)
}
