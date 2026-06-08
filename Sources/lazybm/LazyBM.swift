import ArgumentParser

@main
struct LazyBM: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lazybm",
        abstract: "Organize a browser bookmark export into topic folders using the macOS on-device model.",
        subcommands: [
            Organize.self,
            Doctor.self,
            Dedup.self,
            CheckLinks.self,
            ImportCmd.self,
            ExportCmd.self,
            ListCmd.self,
            SearchCmd.self,
            Undo.self,
            Status.self,
            Eval.self,
        ],
        defaultSubcommand: Organize.self
    )
}
