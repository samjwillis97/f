fn main() {
    let arg = std::env::args().nth(1).expect("no argument given");

    println!("arg: {:?}", arg)
}
