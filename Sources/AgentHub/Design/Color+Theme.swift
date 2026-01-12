//
//  Color+Theme.swift
//  AgentHub
//
//  Created by Assistant on 6/20/25.
//

import SwiftUI

extension Color {
    // MARK: - Primary Purple Palette
    static let primaryPurple = Color(red: 147/255, green: 51/255, blue: 234/255) // #9333EA - Vibrant purple
    static let deepPurple = Color(red: 124/255, green: 58/255, blue: 237/255) // #7C3AED - Deep purple
    static let lightPurple = Color(red: 167/255, green: 139/255, blue: 250/255) // #A78BFA - Light purple
    static let ultraLightPurple = Color(red: 196/255, green: 181/255, blue: 253/255) // #C4B5FD - Ultra light purple
    static let darkPurple = Color(red: 91/255, green: 33/255, blue: 182/255) // #5B21B6 - Dark purple

    // MARK: - Complementary Colors
    static let purpleAccent = Color(red: 217/255, green: 70/255, blue: 239/255) // #D946EF - Pink-purple accent
    static let indigoPurple = Color(red: 99/255, green: 102/255, blue: 241/255) // #6366F1 - Indigo-purple
    static let bluePurple = Color(red: 129/255, green: 140/255, blue: 248/255) // #818CF8 - Blue-purple

    // MARK: - Supporting Colors (Harmonizing with Purple)
    static let warmCoral = Color(red: 251/255, green: 113/255, blue: 133/255) // #FB7185 - Warm coral for errors
    static let softGreen = Color(red: 134/255, green: 239/255, blue: 172/255) // #86EFAC - Soft green for success
    static let goldenAmber = Color(red: 251/255, green: 191/255, blue: 36/255) // #FBBF24 - Golden amber for warnings
    static let skyBlue = Color(red: 125/255, green: 211/255, blue: 252/255) // #7DD3FC - Sky blue for info
    static let lavenderGray = Color(red: 233/255, green: 213/255, blue: 255/255) // #E9D5FF - Lavender gray

    // MARK: - Semantic Colors for Chat
    struct Chat {
        // Assistant message colors
        static let assistantPrimary = primaryPurple
        static let assistantSecondary = lightPurple
        static let assistantAccent = purpleAccent

        // User message colors
        static let userPrimary = indigoPurple
        static let userSecondary = bluePurple

        // Tool colors
        static let toolUse = goldenAmber
        static let toolResult = softGreen
        static let toolError = warmCoral
        static let thinking = skyBlue
        static let webSearch = Color(red: 139/255, green: 92/255, blue: 246/255) // #8B5CF6 - Violet for web search
    }

    // MARK: - Gradient Definitions
    static let purpleGradient = LinearGradient(
        colors: [primaryPurple, deepPurple],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let lightPurpleGradient = LinearGradient(
        colors: [lightPurple, ultraLightPurple],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let subtlePurpleGradient = LinearGradient(
        colors: [primaryPurple.opacity(0.3), primaryPurple.opacity(0.1)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
