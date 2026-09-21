import ArgumentParser

@main
struct Rookmark: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rookmark",
        abstract: "Organize a browser bookmark export into topic folders using the macOS on-device model.",
        subcommands: [
            Organize.self,
            Doctor.self,
            Dedup.self,
            CheckLinks.self,
            ImportCmd.self,
            ImportOrion.self,
            ImportChromium.self,
            ImportFirefox.self,
            ImportSafari.self,
            ExportCmd.self,
            ListCmd.self,
            SearchCmd.self,
            Undo.self,
            Status.self,
            Worksheet.self,
            Eval.self,
        ],
        defaultSubcommand: Organize.self
    )
}
