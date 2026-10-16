import SwiftUI

struct CreativeStudioView: View {
    @Bindable var store: EditorStore
    let project: Project
    @State private var section = "Cutouts"
    var body: some View {
        VStack(alignment: .leading,spacing: 0) {
            HStack {
                ClautoChoice(title: "Creative studio",selection: $section,options: [("Cutouts","Cutouts"),("Fonts","Fonts"),("Graphics","Graphics")])
                Spacer()
            }.padding(.horizontal,28).padding(.vertical,14)
            ClautoRule()
            if section == "Graphics" { GraphicStudioView(controller: store.graphicStudio(for: project)) }
            else if section == "Fonts" { FontStudioView(controller: store.fontStudio(for: project)) }
            else { CutoutStudioView(controller: store.cutoutStudio(for: project)) }
        }
    }
}
