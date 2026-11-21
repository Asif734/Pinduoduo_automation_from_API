import Foundation
import NaturalLanguage

/// Wording instructions and neutral-completion signals used during generation.
enum CustomerFacingReplyPolicy {
    static let wordingBlockedMessage = "Pinduoduo wording blocked this draft. Edit the reply in the merchant app."

    static func preparedForPinduoduo(_ reply: String) -> String {
        reply.replacingOccurrences(of: "调整后仍不行", with: "调整后问题仍然存在")
    }

    /// Included in every new hosted request before the model writes its answer,
    /// even when an operator supplies a custom knowledge/instructions file.
    static let generationInstructions = """
    A video marker without visual evidence does not describe the footage. Answer any usable customer text. If more detail is needed, ask one short question about the problem. Do not imply that you watched the footage.
    Apply this customer-facing wording policy before composing reply_text. Never mention human agents, AI, bots, or automation in customer-visible text, including translations such as 人工、真人、人工智能、机器人、自动客服、自动回复. Do not claim to be a human or a real person. Do not echo those labels from a customer's message or use them in a clarification question. Do not ask whether the customer wants a human agent.
    For an unclear request to switch or transfer service (including a possible typo such as 转亭子), ask one useful question about the customer's actual need or offer help: 您想咨询什么问题？我来帮您看看。 / What would you like help with? Do not invent the intended recipient or promise a transfer. If the product issue is already clear, continue helping with it rather than asking the customer to repeat it. When an existing approved condition authorizes a transfer, use neutral colleague wording: 我为您转接同事继续协助。 / I'll ask a colleague to continue assisting. Keep action and transfer_reason internal, and never describe a colleague as human or as performing special verification. Silently check these rules while drafting; return only the seven-field JSON object, with no policy explanation.
    """

    private static let prohibitedPatterns: [(String, String)] = [
        (#"\b(?:I|we)\s+(?:can(?:not|['’]t)|am\s+unable\s+to|are\s+unable\s+to)\s+(?:view|watch|see|access|open)\s+(?:(?:your|the|this)\s+)?video\b|\b(?:your|the|this)\s+video\s+is\s+(?:still\s+)?(?:loading|processing)\b"#, "video processing status"),
        (#"(?:我|我们|这边).{0,8}(?:无法|不能|看不到|看不了).{0,8}视频|视频.{0,6}(?:还在|仍在|正在)?(?:加载|处理中)"#, "video processing status"),
        (#"(?<![A-Za-z0-9])AI(?![A-Za-z0-9])"#, "AI"),
        (#"\bartificial\s+intelligence\b"#, "artificial intelligence"),
        (#"\bchat\s*bot\b|\bbot\b|\brobots?\b"#, "bot"),
        (#"\bautomation\b|\bautomated\s+(?:assistant|support|service|reply)\b"#, "automation"),
        (#"\b(?:human|live)\s+(?:agent|support|representative|customer\s+service)\b"#, "human agent"),
        (#"\b(?:I(?:['’]m|\s+am)|we(?:['’]re|\s+are))\s+(?:a\s+)?(?:real\s+)?(?:human|person|people)\b"#, "technical identity"),
        (#"\bafter[- ]sales\s+agent\b"#, "after-sales agent"),
        (#"\b(?:agent|representative|colleague|support\s+(?:team|staff)|after[- ]sales\s+(?:team|staff))\b(?:\s*,?\s*(?:who|will|would|can|must|needs?\s+to|has\s+to|is\s+going\s+to|help\s+you|further)){0,5}\s+(?:verify|review|check|confirm)\b"#, "handoff verification"),
        (#"(?:人工|真人|机器人|自动客服|自动回复|自动化)"#, "technical identity"),
        (#"(?:客服|售后人员|售后同事|同事)(?:需要|将|会|来|为您|帮您|协助您|负责){0,4}(?:核实|审核|验证)"#, "handoff verification")
    ]

    static func violation(in reply: String) -> String? {
        for (pattern, label) in prohibitedPatterns
        where reply.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return label
        }
        return nil
    }
}

enum CustomerFacingFallback {
    static func productProblemQuestion(history: [PDDChatMessage]) -> String {
        let recognizer = NLLanguageRecognizer()
        for message in history.reversed() where message.sender == .customer && message.kind == .text {
            recognizer.reset(); recognizer.processString(message.content)
            switch recognizer.dominantLanguage {
            case .english: return "What problem are you having with the product? Please describe what happens so I can help you troubleshoot."
            case .spanish: return "¿Qué problema tienes con el producto? Describe qué ocurre para que pueda ayudarte."
            case .french: return "Quel problème rencontrez-vous avec le produit ? Décrivez ce qui se passe pour que je puisse vous aider."
            case .german: return "Welches Problem haben Sie mit dem Produkt? Bitte beschreiben Sie, was passiert, damit ich Ihnen helfen kann."
            case .japanese: return "製品にどのような問題が起きていますか？具体的な症状を教えていただければ、対処方法をご案内します。"
            case .korean: return "제품에 어떤 문제가 있나요? 구체적인 증상을 설명해 주시면 해결을 도와드리겠습니다."
            case .bengali: return "পণ্যটিতে কী সমস্যা হচ্ছে? কী ঘটছে তা একটু বর্ণনা করুন, আমি সমাধানে সাহায্য করব।"
            case .hindi: return "उत्पाद में क्या समस्या आ रही है? कृपया बताएं कि क्या होता है, ताकि मैं मदद कर सकूं।"
            case .arabic: return "ما المشكلة التي تواجهها مع المنتج؟ يرجى وصف ما يحدث كي أساعدك في حلها."
            case .portuguese: return "Qual é o problema com o produto? Descreva o que acontece para que eu possa ajudar."
            case .russian: return "Какая проблема возникла с товаром? Опишите, что происходит, чтобы я мог помочь."
            case .simplifiedChinese, .traditionalChinese: return "请问您的产品遇到了什么问题？麻烦您描述一下具体表现，我来帮您排查。"
            default: continue
            }
        }
        return "请问您的产品遇到了什么问题？麻烦您描述一下具体表现，我来帮您排查。"
    }

    static func videoQuestion(history: [PDDChatMessage]) -> String {
        let recognizer = NLLanguageRecognizer()
        for message in history.reversed() where message.sender == .customer && message.kind == .text {
            recognizer.reset(); recognizer.processString(message.content)
            switch recognizer.dominantLanguage {
            case .english: return "What would you like me to check in the video?"
            case .spanish: return "¿Qué te gustaría que revisara en el vídeo?"
            case .french: return "Que souhaitez-vous que je vérifie dans la vidéo ?"
            case .german: return "Was soll ich im Video überprüfen?"
            case .japanese: return "動画のどの点を確認すればよいですか？"
            case .korean: return "영상에서 어떤 부분을 확인해 드릴까요?"
            case .bengali: return "ভিডিওর কোন বিষয়টি আপনি আমাকে দেখতে বলছেন?"
            case .hindi: return "आप वीडियो में किस बात की जाँच करवाना चाहते हैं?"
            case .arabic: return "ما الذي تود مني التحقق منه في الفيديو؟"
            case .portuguese: return "O que gostaria que eu verificasse no vídeo?"
            case .russian: return "Что вы хотите, чтобы я проверил в видео?"
            case .simplifiedChinese, .traditionalChinese: return "您希望我重点帮您查看视频中的哪个问题？"
            default: continue
            }
        }
        return "您希望我重点帮您查看视频中的哪个问题？"
    }

    static func handoff(history: [PDDChatMessage]) -> String {
        let recognizer = NLLanguageRecognizer()
        for message in history.reversed() where message.sender == .customer && message.kind == .text {
            recognizer.reset(); recognizer.processString(message.content)
            switch recognizer.dominantLanguage {
            case .english: return "I’ll transfer you to a colleague for further assistance."
            case .spanish: return "Te pasaré con un compañero para que continúe ayudándote."
            case .french: return "Je vais vous mettre en relation avec un collègue pour poursuivre votre demande."
            case .german: return "Ich leite Sie an einen Kollegen weiter, der Ihnen weiterhilft."
            case .japanese: return "引き続き対応できる担当者におつなぎします。"
            case .korean: return "계속 도와드릴 수 있도록 다른 담당자에게 연결해 드리겠습니다."
            case .bengali: return "আরও সহায়তার জন্য আপনাকে একজন সহকর্মীর কাছে স্থানান্তর করছি।"
            case .hindi: return "आगे की सहायता के लिए मैं आपको एक सहकर्मी से जोड़ूँगा।"
            case .arabic: return "سأحوّلك إلى زميل لمواصلة مساعدتك."
            case .portuguese: return "Vou encaminhar você a um colega para continuar o atendimento."
            case .russian: return "Я передам ваш чат коллеге для дальнейшей помощи."
            case .simplifiedChinese, .traditionalChinese: return "我为您转接同事继续协助。"
            default: continue
            }
        }
        return "我为您转接同事继续协助。"
    }
}
