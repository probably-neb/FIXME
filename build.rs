fn main() {
    cynic_codegen::register_schema("linear")
        .from_sdl_file("src/linear/schema.graphql")
        .unwrap()
        .as_default()
        .unwrap();
    eprintln!("Generated linear schema successfully!")
}
